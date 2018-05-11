//
//  DatabaseManager.swift
//  ExponeaSDK
//
//  Created by Ricardo Tokashiki on 03/04/2018.
//  Copyright © 2018 Exponea. All rights reserved.
//

import Foundation
import CoreData

/// The Entities Manager class is responsible for persist the data using CoreData Framework.
/// Persisted data will be used to interact with the Exponea API.
public class DatabaseManager {

    internal lazy var persistentContainer: NSPersistentContainer = {
        let bundle = Bundle(for: DatabaseManager.self)
        let container = NSPersistentContainer(name: "DatabaseModel", bundle: bundle)!
        
        container.loadPersistentStores(completionHandler: { (_, error) in
            if let error = error {
                Exponea.logger.log(.error, message: "Unresolved error \(error.localizedDescription).")
            }
        })
        
        container.viewContext.automaticallyMergesChangesFromParent = true
        
        return container
    }()

    init() {
        #if DISABLE_PERSISTENCE
        Exponea.logger.log(.warning, message: "Disable persistence flag is active, clearing database contents.")
        
        let coordinator = persistentContainer.persistentStoreCoordinator
        guard let url = persistentContainer.persistentStoreDescriptions.first?.url else {
            Exponea.logger.log(.error, message: "Can't get url of persistent store, clearing failed.")
            return
        }
    
        do {
            try coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
            Exponea.logger.log(.verbose, message: "Database contents cleared.")
            
            persistentContainer.loadPersistentStores(completionHandler: { _, error in
                if let error = error {
                    Exponea.logger.log(.error, message: "Failed to create new database: \(error.localizedDescription).")
                }
            })
            
        } catch {
            Exponea.logger.log(.error, message: "Error clearing database: \(error.localizedDescription)")
        }
        #endif
    }

    /// Managed Context for Core Data
    var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }

    /// Save all changes in CoreData
    func saveContext(object: NSManagedObject) {
        do {
            try object.managedObjectContext?.save()
        } catch {
            Exponea.logger.log(.error, message: "Unresolved error \(error.localizedDescription)")
        }
    }

    /// Save all changes in CoreData
    func saveContext() throws {
        if context.hasChanges {
            try context.save()
        }
    }

    /// Delete a specific object in CoreData
    fileprivate func deleteObject(_ object: NSManagedObject) throws {
        context.delete(object)
        try saveContext()
    }

}

extension DatabaseManager: DatabaseManagerType {

    /// Add any type of event into coredata.
    ///
    /// - Parameters:
    ///     - projectToken: Project token (you can find it in the overview section of your Exponea project)
    ///     - customerId: “cookie” for identifying anonymous customers or “registered” for identifying known customers)
    ///     - properties: Properties that should be updated
    ///     - timestamp: Timestamp should always be UNIX timestamp format
    ///     - eventType: Type of event to be tracked
    public func trackEvent(with data: [DataType]) throws {
        let trackEvent = TrackEvent(context: context)

        for type in data {
            switch type {
            case .projectToken(let token):
                trackEvent.projectToken = token
                
            case .customerId(let id):
                trackEvent.customerIdKey = id.key
                trackEvent.customerIdValue = id.value as? NSObject

            case .eventType(let event):
                trackEvent.eventType = event

            case .timestamp(let time):
                trackEvent.timestamp = time ?? Date().timeIntervalSince1970

            case .properties(let properties):
                // Add the event properties to the events entity
                for property in properties {
                    let trackEventProperties = TrackEventProperty(context: context)
                    trackEventProperties.key = property.key
                    trackEventProperties.value = property.value as? NSObject
                    trackEvent.addToTrackEventProperties(trackEventProperties)
                }
            default:
                break
            }
        }
        
        Exponea.logger.log(.verbose, message: "Adding track event to database: \(trackEvent.objectID)")

        // Insert the object into the database
        context.insert(trackEvent)
        
        // Save the customer properties into CoreData
        try saveContext()
    }
    
    public func trackEvent(with event: TrackEvent) throws {
        let request: NSFetchRequest<TrackEvent> = TrackEvent.fetchRequest()
        request.predicate = NSPredicate(format: "objectID == %@", event.objectID)
        
        guard try context.count(for: request) == 0 else {
            Exponea.logger.log(.warning, message: "Object already exists in database, skipping tracking.")
            return
        }
        
        // Insert and save
        context.insert(event)
        try saveContext()
    }
    
    /// Add customer properties into the database.
    ///
    /// - Parameter data: See `DataType` for more information. Types specified below are required at minimum.
    ///     - `projectToken`
    ///     - `customerId`
    ///     - `properties`
    ///     - `timestamp`
    /// - Throws: <#throws value description#>
    public func trackCustomer(with data: [DataType]) throws {
        let trackCustomer = TrackCustomer(context: context)
        let trackCustomerProperties = TrackCustomerProperties(context: context)

        for type in data {
            switch type {
            case .projectToken(let token):
                trackCustomer.projectToken = token

            case .customerId(let id):
                trackCustomer.customerIdKey = id.key
                trackCustomer.customerIdValue = id.value as? NSObject

            case .timestamp(let time):
                trackCustomer.timestamp = time ?? Date().timeIntervalSince1970

            case .properties(let properties):
                // Add the customer properties to the customer entity
                for property in properties {
                    trackCustomerProperties.key = property.key
                    trackCustomerProperties.value = property.value as? NSObject
                    trackCustomer.addToTrackCustomerProperties(trackCustomerProperties)
                }
            default:
                break
            }
        }

        // Save the customer properties into CoreData
        try saveContext()
    }
    
    public func trackCustomer(with customer: TrackCustomer) throws {
        let request: NSFetchRequest<TrackCustomer> = TrackCustomer.fetchRequest()
        request.predicate = NSPredicate(format: "objectID == %@", customer.objectID)
        
        guard try context.count(for: request) == 0 else {
            Exponea.logger.log(.warning, message: "Object already exists in database, skipping tracking.")
            return
        }
        
        // Insert and save
        context.insert(customer)
        try saveContext()
    }

    public func fetchOrCreateCustomer() -> Customer {
        do {
            let customer: [Customer] = try context.fetch(Customer.fetchRequest())
            return customer.first!
        } catch {
            Exponea.logger.log(.warning, message: "No customer found saved in database, will create. \(error)")
        }
        
        let customer = Customer(context: context)
        customer.cookie = UUID()
        
        do {
            try saveContext()
        } catch {
            let error = DatabaseManagerError.saveCustomerFailed(error.localizedDescription).localizedDescription
            Exponea.logger.log(.error, message: error)
        }
        
        return customer
    }
    
    /// Fetch all Tracking Customers from CoreData
    ///
    /// - Returns: An array of tracking customer updates, if any are stored in the database.
    public func fetchTrackCustomer() throws -> [TrackCustomer] {
        return try context.fetch(TrackCustomer.fetchRequest())
    }
    
    /// Fetch all Tracking Events from CoreData
    ///
    /// - Returns: An array of tracking events, if any are stored in the database.
    public func fetchTrackEvent() throws -> [TrackEvent] {
        return try context.fetch(TrackEvent.fetchRequest())
    }

    /// Detele a Tracking Event Object from CoreData
    ///
    /// - Parameters:
    ///     - object: Tracking Event Object to be deleted from CoreData
    public func delete(_ object: TrackEvent) throws {
        try deleteObject(object)
    }

    /// Detele a Tracking Customer Object from CoreData
    ///
    /// - Parameters:
    ///     - object: Tracking Customer Object to be deleted from CoreData
    public func delete(_ object: TrackCustomer) throws {
        try deleteObject(object)
    }
}
