//
//  SwiftPyICloud.swift
//  swiftpy-icloud
//
//  Created by Tibor Felföldy on 2026-09-03.
//

import CloudKit
import SwiftPy

@MainActor
public enum SwiftPyICloud {
    /// Whether records can be saved: now, and again whenever the iCloud account
    /// changes. Fetching works either way.
    public static func accountAvailability() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                continuation.yield(await ICloud.shared.isAccountAvailable())
                for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                    continuation.yield(await ICloud.shared.isAccountAvailable())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// - Parameter containerIdentifier: The container to use instead of the one
    ///   derived from the bundle id. An App Clip has to name its parent app's
    ///   container, since it shares the records but not the bundle id.
    public static func initialize(containerIdentifier: String? = nil) {
        ICloud.shared.containerIdentifier = containerIdentifier

        PyBind.module("icloud", docs: """
        Share ``modeling.model`` instances through iCloud.

        Saving a model returns an id. Anyone with that id can fetch the model,
        so this is public data. Saving needs an iCloud account; fetching does
        not. Only the account that saved a record can change or delete it.

        ```python
        from modeling import model
        import icloud

        @model
        class Item:
            name: str
            quantity: int = 1

        id = await icloud.save(Item('Hammer', 2))
        item = await icloud.fetch(Item, id)
        ```
        """) { module in
            module.asyncDef(
                "save(model) -> str",
                docstring: """
                Saves a model to iCloud and returns its record id. Await the result.

                model: An instance of a class created with the ``modeling.model``
                decorator.

                The returned id is remembered on the instance, so saving it again
                updates the same record instead of creating another one. Changing a
                field does not push anything on its own; call `save` again.

                Raises `RuntimeError` when no iCloud account is signed in, and when
                the record belongs to another account.
                """
            ) { argc, argv in
                PyBind.function(argc, argv, ICloud.shared.save)
            }

            module.asyncDef(
                "fetch(type, id: str) -> Any",
                docstring: """
                Fetches the model saved under the given id. Await the result.

                type: The class to decode the record into, created with the
                ``modeling.model`` decorator.
                id: A record id returned by ``icloud.save``.

                Works without an iCloud account. Raises `KeyError` when no record
                has that id, and `ValueError` when the record holds a different
                type of model.
                """
            ) { argc, argv in
                PyBind.function(argc, argv, ICloud.shared.fetch)
            }

            module.asyncDef(
                "delete(id: str) -> None",
                docstring: """
                Deletes the record with the given id. Await the result.

                id: A record id returned by ``icloud.save``.

                Raises `RuntimeError` unless the record was saved by this account.
                """
            ) { argc, argv in
                PyBind.function(argc, argv, ICloud.shared.delete)
            }
        }
    }
}
