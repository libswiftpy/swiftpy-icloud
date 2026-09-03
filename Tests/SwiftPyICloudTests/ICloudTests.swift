//
//  ICloudTests.swift
//  swiftpy-icloud
//
//  Created by Tibor Felföldy on 2026-09-03.
//

import Testing
import CloudKit
import Foundation
import SwiftPy
@testable import SwiftPyICloud

/// The record round-trip and error mapping only. A test bundle has no iCloud
/// entitlement, so nothing here may reach the container.
@MainActor
struct ICloudTests {
    init() {
        Interpreter.run("""
        from modeling import model

        @model
        class Item:
            name: str = ''
            quantity: int = 0

        class Plain:
            pass
        """)
    }

    // MARK: - encode

    @Test func encodesFieldsAsJSON() throws {
        let model: PyObject = try #require(Interpreter.evaluate("Item('Sword', 2)"))

        let (id, name, json) = try ICloud.shared.encode(model)

        #expect(id == nil)
        #expect(name == "Item")
        #expect(json == #"{"name": "Sword", "quantity": 2}"#)
    }

    @Test func encodesTheIdOfAnAlreadySavedModel() throws {
        Interpreter.run("""
        _saved = Item('Shield')
        _saved._icloud_id = 'record-1'
        """)
        let model: PyObject = try #require(Interpreter.evaluate("_saved"))

        #expect(try ICloud.shared.encode(model).id == "record-1")
    }

    @Test func encodingAnUndecoratedClassRaisesTypeError() throws {
        let model: PyObject = try #require(Interpreter.evaluate("Plain()"))

        let error = #expect(throws: PythonError.self) {
            try ICloud.shared.encode(model)
        }

        #expect(error?.type == .TypeError)
    }

    // MARK: - decode

    @Test func decodesJSONIntoTheModel() throws {
        let type: PyObject = try #require(Interpreter.evaluate("Item"))

        let model = try ICloud.shared.decode(
            #"{"name": "Shield", "quantity": 3}"#,
            name: "Item",
            into: type,
            id: "record-1"
        )

        let name: String? = model.name
        let quantity: Int? = model.quantity
        let id: String? = model._icloud_id
        #expect(name == "Shield")
        #expect(quantity == 3)
        #expect(id == "record-1")
    }

    @Test func decodingAnotherModelsRecordRaisesValueError() throws {
        let type: PyObject = try #require(Interpreter.evaluate("Item"))

        let error = #expect(throws: PythonError.self) {
            try ICloud.shared.decode(
                #"{"name": "Shield"}"#,
                name: "Crate",
                into: type,
                id: "record-1"
            )
        }

        #expect(error?.type == .ValueError)
    }

    @Test func decodingIntoAnUndecoratedClassRaisesTypeError() throws {
        let type: PyObject = try #require(Interpreter.evaluate("Plain"))

        let error = #expect(throws: PythonError.self) {
            try ICloud.shared.decode("{}", name: "Plain", into: type, id: "record-1")
        }

        #expect(error?.type == .TypeError)
    }

    // MARK: - exception mapping

    @Test func mapsCloudKitFailuresToPythonExceptions() {
        #expect(exception(for: .notAuthenticated).message?.contains("Sign in to iCloud") == true)
        #expect(exception(for: .permissionFailure).message?.contains("record-1") == true)
        #expect(exception(for: .unknownItem)?.type == .KeyError)
        #expect(exception(for: .networkUnavailable)?.type == .RuntimeError)
        #expect(exception(for: .quotaExceeded)?.type == .RuntimeError)
    }

    @Test func keepsACancelledOperationCancelled() {
        let error = ICloud.shared.exception(
            for: ckError(.operationCancelled),
            id: "record-1"
        )

        #expect(error is CancellationError)
    }

    private func ckError(_ code: CKError.Code) -> CKError {
        CKError(_nsError: NSError(domain: CKError.errorDomain, code: code.rawValue))
    }

    private func exception(for code: CKError.Code) -> PythonError? {
        ICloud.shared.exception(for: ckError(code), id: "record-1") as? PythonError
    }
}

private extension Optional where Wrapped == PythonError {
    var message: String? { self?.errorDescription }
}
