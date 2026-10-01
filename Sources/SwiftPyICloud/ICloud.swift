//
//  ICloud.swift
//  swiftpy-icloud
//
//  Created by Tibor Felföldy on 2026-09-03.
//

import CloudKit
import Foundation
import SwiftPy

@MainActor
final class ICloud {
    static let shared = ICloud()

    /// Every model shares one record type, because CloudKit only creates record
    /// types just-in-time in development and Python classes are defined at runtime.
    nonisolated static let recordType = "Model"

    /// Set before first use. An App Clip has its own bundle id, and
    /// `CKContainer.default()` derives the container from that rather than from
    /// the entitlement, so it would resolve to a container that does not exist.
    var containerIdentifier: String?

    var database: ICloudDatabase {
        ICloudDatabase(containerIdentifier: containerIdentifier)
    }

    /// Whether an iCloud account is signed in, which saving and deleting need.
    func isAccountAvailable() async -> Bool {
        await database.isAccountAvailable()
    }

    func save(model: PyObject) async throws -> String {
        let id = try await upload(model).save()
        model._icloud_id = id
        return id
    }

    /// Encodes the model now, so the save can run off the main actor.
    func upload(_ model: PyObject) throws(PythonError) -> ICloudUpload {
        let (id, name, json) = try encode(model)
        return ICloudUpload(database: database, id: id, name: name, json: json)
    }

    func fetch(type: PyObject, id: String) async throws -> PyObject {
        let record: CKRecord

        do {
            record = try await database.cloud.record(for: CKRecord.ID(recordName: id))
        } catch {
            throw exception(for: error, id: id)
        }

        guard record.recordType == Self.recordType,
              let name = record["name"] as? String,
              let json = record["json"] as? String else {
            throw PythonError.ValueError("Record '\(id)' does not hold a model.")
        }

        return try decode(json, name: name, into: type, id: id)
    }

    func delete(id: String) async throws {
        try await database.requireAccount()
        do {
            _ = try await database.cloud.deleteRecord(withID: CKRecord.ID(recordName: id))
        } catch {
            throw exception(for: error, id: id)
        }
    }

    // MARK: - Conversion

    /// The record id already on the model, its class name, and its fields as JSON.
    func encode(_ model: PyObject) throws(PythonError) -> (id: String?, name: String, json: String) {
        let name = py.typeof(model.reference).name

        guard let fields = model._fields else {
            throw .TypeError("'\(name)' is not a modeling.model.")
        }

        guard let json: String = try py.module("json")?.dumps?(fields) else {
            throw .ValueError("Could not serialize '\(name)'.")
        }

        let id: String? = model._icloud_id
        return (id, name, json)
    }

    func decode(_ json: String, name: String, into type: PyObject, id: String) throws(PythonError) -> PyObject {
        let typeName = py.totype(type.reference).name

        guard typeName == name else {
            throw .ValueError("Record '\(id)' holds a '\(name)', not a '\(typeName)'.")
        }

        guard let fromJSON = type._from_json else {
            throw .TypeError("'\(typeName)' is not a modeling.model.")
        }

        guard let model: PyObject = try fromJSON(json) else {
            throw .ValueError("Could not decode a '\(typeName)' from record '\(id)'.")
        }

        model._icloud_id = id
        return model
    }

    /// Translates a CloudKit failure into the matching Python exception. A stop
    /// stays a `CancellationError`, so it unwinds without raising into the card.
    nonisolated func exception(for error: any Error, id: String) -> any Error {
        Self.exception(for: error, id: id)
    }

    nonisolated static func exception(for error: any Error, id: String) -> any Error {
        let ckError = error as? CKError

        if error is CancellationError || ckError?.code == .operationCancelled {
            return CancellationError()
        }

        return switch ckError?.code {
        case .notAuthenticated:
            PythonError.RuntimeError("Sign in to iCloud to save or delete records.")
        case .permissionFailure:
            PythonError.RuntimeError("Only the account that saved record '\(id)' can change it.")
        case .unknownItem:
            PythonError.KeyError(id)
        case .networkUnavailable, .networkFailure:
            PythonError.RuntimeError("Could not reach iCloud: \(error.localizedDescription)")
        case .quotaExceeded:
            PythonError.RuntimeError("The iCloud storage quota is exceeded.")
        default:
            PythonError.RuntimeError(error.localizedDescription)
        }
    }
}

/// A model encoded for iCloud, so it can be saved from any thread.
public struct ICloudUpload: Sendable {
    let database: ICloudDatabase
    let id: String?
    let name: String
    let json: String

    /// Saves the record off the main actor and returns its id.
    @concurrent public func save() async throws -> String {
        try await database.save(id: id, name: name, json: json)
    }
}

/// The CloudKit side, free of Python, so it runs off the main actor.
struct ICloudDatabase: Sendable {
    let containerIdentifier: String?

    /// Resolved on use rather than at init: a bundle without a container traps.
    private var container: CKContainer {
        if let containerIdentifier {
            CKContainer(identifier: containerIdentifier)
        } else {
            CKContainer.default()
        }
    }

    var cloud: CKDatabase { container.publicCloudDatabase }

    @concurrent func isAccountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    /// Without an account CloudKit refuses writes as a permission failure,
    /// which would read as someone else owning the record.
    @concurrent func requireAccount() async throws {
        guard await isAccountAvailable() else {
            throw PythonError.RuntimeError("Sign in to iCloud to save or delete records.")
        }
    }

    @concurrent func save(id existingId: String?, name: String, json: String) async throws -> String {
        try await requireAccount()

        if let existingId {
            let record = record(id: existingId, name: name, json: json)
            do {
                try await save(record, policy: .allKeys)
            } catch {
                throw ICloud.exception(for: error, id: existingId)
            }
            return existingId
        }

        for _ in 0..<5 {
            let id = Self.shortId()
            let record = record(id: id, name: name, json: json)

            do {
                try await save(record, policy: .ifServerRecordUnchanged)
                return id
            } catch {
                guard Self.isCollision(error) else {
                    throw ICloud.exception(for: error, id: id)
                }
            }
        }

        throw PythonError.RuntimeError("Could not create a unique iCloud record ID.")
    }

    private func record(id: String, name: String, json: String) -> CKRecord {
        let record = CKRecord(
            recordType: ICloud.recordType,
            recordID: CKRecord.ID(recordName: id)
        )
        record["name"] = name
        record["json"] = json
        return record
    }

    private func save(
        _ record: CKRecord,
        policy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws {
        let results = try await cloud.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: policy,
            atomically: false
        ).saveResults

        guard let result = results[record.recordID] else {
            throw PythonError.RuntimeError("iCloud did not return a save result.")
        }
        _ = try result.get()
    }

    private static let idAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// Ten alphanumeric characters provide ~60 bits of randomness. No `_`:
    /// CloudKit rejects record names that start with one.
    private static func shortId() -> String {
        String((0..<10).map { _ in idAlphabet.randomElement()! })
    }

    private static func isCollision(_ error: any Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .serverRecordChanged { return true }
        return error.partialErrorsByItemID?.values.contains {
            ($0 as? CKError)?.code == .serverRecordChanged
        } == true
    }
}
