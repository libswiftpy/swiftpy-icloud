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
    static let recordType = "Model"

    // CKContainer.default() reads the app's entitlement, so resolve it on first
    // use rather than at init — a bundle without a container traps.
    private lazy var database = CKContainer.default().publicCloudDatabase

    func save(model: PyObject) async throws -> String {
        let (existingId, name, json) = try encode(model)
        let recordId = CKRecord.ID(recordName: existingId ?? UUID().uuidString)

        let record = CKRecord(recordType: Self.recordType, recordID: recordId)
        record["name"] = name
        record["json"] = json

        do {
            // .allKeys skips the change tag check, so re-saving a model
            // overwrites its record instead of failing as serverRecordChanged.
            _ = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys
            )
        } catch {
            throw exception(for: error, id: recordId.recordName)
        }

        model._icloud_id = recordId.recordName
        return recordId.recordName
    }

    func fetch(type: PyObject, id: String) async throws -> PyObject {
        let record: CKRecord

        do {
            record = try await database.record(for: CKRecord.ID(recordName: id))
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
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: id))
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
    func exception(for error: any Error, id: String) -> any Error {
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
