//
//  LiveList.swift
//  CoreStore
//
//  Copyright © 2018 John Rommel Estropia
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import CoreData

#if canImport(Combine)
import Combine

#endif

#if canImport(SwiftUI)
import SwiftUI

#endif


// MARK: - LiveList

/**
 `LiveList` tracks a diffable list of `DynamicObject` instances. Unlike `ListMonitor`s, `LiveList` are more lightweight and access objects lazily. `LiveList`s are also designed to work well with `DiffableDataSource.TableView`s and `DiffableDataSource.CollectionView`s. Objects that need to be notified of `LiveList` changes may register themselves to its `addObserver(_:_:)` method:
 ```
 let liveList = Shared.defaultStack.liveList(
     From<Person>()
         .where(\.title == "Engineer")
         .orderBy(.ascending(\.lastName))
 )
 liveList.addObserver(self) { (liveList) in
 
     // Handle changes
 }
 ```
 The `LiveList` instance needs to be held on (retained) for as long as the list needs to be observed.
 Observers registered via `addObserver(_:_:)` are not retained. `LiveList` only keeps a `weak` reference to all observers, thus keeping itself free from retain-cycles.
 
 `LiveList`s may optionally be created with sections:
 ```
 let liveList = Shared.defaultStack.liveList(
     From<Person>()
         .sectionBy(\.age") { "Age \($0)" }
         .where(\.title == "Engineer")
         .orderBy(.ascending(\.lastName))
 )
 liveList.addObserver(self) { (liveList) in
 
     // Handle changes
 }
 ```
 */
@available(macOS 10.12, *)
public final class LiveList<O: DynamicObject>: Hashable {
    
    // MARK: Public

    public typealias SectionID = SnapshotType.SectionID
    public typealias ItemID = SnapshotType.ItemID

    public subscript(section sectionID: SectionID) -> [LiveObject<O>] {

        let context = self.context
        return self.snapshot
            .itemIdentifiers(inSection: sectionID)
            .map({ context.liveObject(objectID: $0) })
    }

    public subscript(itemID itemID: ItemID) -> LiveObject<O>? {

        guard let validID = self.snapshot.itemIdentifiers.first(where: { $0 == itemID }) else {

            return nil
        }
        return self.context.liveObject(objectID: validID)
    }

    public subscript(indexPath indexPath: IndexPath) -> LiveObject<O>? {
        
        let snapshot = self.snapshot
        let sectionIdentifiers = snapshot.sectionIdentifiers
        guard sectionIdentifiers.indices.contains(indexPath.section) else {
            
            return nil
        }
        let sectionID = sectionIdentifiers[indexPath.section]
        let itemIdentifiers = snapshot.itemIdentifiers(inSection: sectionID)
        guard itemIdentifiers.indices.contains(indexPath.item) else {
            
            return nil
        }
        let itemID = itemIdentifiers[indexPath.item]
        return self.context.liveObject(objectID: itemID)
    }

    public subscript<S: Sequence>(section sectionID: SectionID, itemIndices itemIndices: S) -> [LiveObject<O>] where S.Element == Int {

        let context = self.context
        let itemIDs = self.snapshot.itemIdentifiers(inSection: sectionID)
        return itemIndices.map { position in

            let itemID = itemIDs[position]
            return context.liveObject(objectID: itemID)
        }
    }

    public fileprivate(set) var snapshot: SnapshotType = .init() {

        willSet {

            self.willChange()
        }
        didSet {
            
            self.notifyObservers()
            self.didChange()
        }
    }

    public var numberOfItems: Int {

        return self.snapshot.numberOfItems
    }

    public var numberOfSections: Int {

        return self.snapshot.numberOfSections
    }

    public var sectionIdentifiers: [SectionID] {

        return self.snapshot.sectionIdentifiers
    }

    public var items: [LiveObject<O>] {

        let context = self.context
        return self.snapshot.itemIdentifiers
            .map({ context.liveObject(objectID: $0) })
    }

    public func numberOfItems(inSection identifier: SectionID) -> Int {

        return self.snapshot.numberOfItems(inSection: identifier)
    }

    public func items(inSection identifier: SectionID) -> [LiveObject<O>] {

        let context = self.context
        return self.snapshot
            .itemIdentifiers(inSection: identifier)
            .map({ context.liveObject(objectID: $0) })
    }

    public func items(inSection identifier: SectionID, atIndices indices: IndexSet) -> [LiveObject<O>] {

        let context = self.context
        let itemIDs = self.snapshot.itemIdentifiers(inSection: identifier)
        return indices.map { position in

            let itemID = itemIDs[position]
            return context.liveObject(objectID: itemID)
        }
    }

    public func section(containingItem item: LiveObject<O>) -> SectionID? {

        return self.snapshot.sectionIdentifier(containingItem: item.objectID())
    }

    public func indexOfItem(_ item: LiveObject<O>) -> Int? {

        return self.snapshot.indexOfItem(item.objectID())
    }

    public func indexOfSection(_ identifier: SectionID) -> Int? {

        return self.snapshot.indexOfSection(identifier)
    }
    
    public func addObserver<T: AnyObject>(_ observer: T, _ callback: @escaping (LiveList<O>) -> Void) {
        
        self.observers.setObject(
            Internals.Closure(callback),
            forKey: observer
        )
    }
    
    public func removeObserver<T: AnyObject>(_ observer: T) {
        
        self.observers.removeObject(forKey: observer)
    }


    // MARK: Public (Refetching)

    /**
     Asks the `ListMonitor` to refetch its objects using the specified series of `FetchClause`s. Note that this method does not execute the fetch immediately; the actual fetching will happen after the `NSFetchedResultsController`'s last `controllerDidChangeContent(_:)` notification completes.

     `refetch(...)` broadcasts `listMonitorWillRefetch(...)` to its observers immediately, and then `listMonitorDidRefetch(...)` after the new fetch request completes.

     - parameter fetchClauses: a series of `FetchClause` instances for fetching the object list. Accepts `Where`, `OrderBy`, and `Tweak` clauses.
     - Important: Starting CoreStore 4.0, all `FetchClause`s required by the `ListMonitor` should be provided in the arguments list of `refetch(...)`.
     */
    public func refetch(_ fetchClauses: FetchClause...) {

        self.refetch(fetchClauses)
    }

    /**
     Asks the `ListMonitor` to refetch its objects using the specified series of `FetchClause`s. Note that this method does not execute the fetch immediately; the actual fetching will happen after the `NSFetchedResultsController`'s last `controllerDidChangeContent(_:)` notification completes.

     `refetch(...)` broadcasts `listMonitorWillRefetch(...)` to its observers immediately, and then `listMonitorDidRefetch(...)` after the new fetch request completes.

     - parameter fetchClauses: a series of `FetchClause` instances for fetching the object list. Accepts `Where`, `OrderBy`, and `Tweak` clauses.
     - Important: Starting CoreStore 4.0, all `FetchClause`s required by the `ListMonitor` should be provided in the arguments list of `refetch(...)`.
     */
    public func refetch(_ fetchClauses: [FetchClause]) {

        self.refetch { (fetchRequest) in

            fetchClauses.forEach { $0.applyToFetchRequest(fetchRequest) }
        }
    }


    // MARK: Public (3rd Party Utilities)

    /**
     Allow external libraries to store custom data in the `ListMonitor`. App code should rarely have a need for this.
     ```
     enum Static {
         static var myDataKey: Void?
     }
     monitor.userInfo[&Static.myDataKey] = myObject
     ```
     - Important: Do not use this method to store thread-sensitive data.
     */
    public let userInfo = UserInfo()


    // MARK: Equatable

    public static func == (_ lhs: LiveList, _ rhs: LiveList) -> Bool {

        return lhs === rhs
    }


    // MARK: Hashable

    public func hash(into hasher: inout Hasher) {

        hasher.combine(ObjectIdentifier(self))
    }
    
    
    // MARK: LiveResult
    
    public typealias ObjectType = O
    
    public typealias SnapshotType = ListSnapshot<O>


    // MARK: Internal

    internal convenience init(dataStack: DataStack, from: From<ObjectType>, sectionBy: SectionBy<ObjectType>?, applyFetchClauses: @escaping (_ fetchRequest: Internals.CoreStoreFetchRequest<NSManagedObject>) -> Void) {

        self.init(
            context: dataStack.mainContext,
            from: from,
            sectionBy: sectionBy,
            applyFetchClauses: applyFetchClauses,
            createAsynchronously: nil
        )
    }

    internal convenience init(dataStack: DataStack, from: From<ObjectType>, sectionBy: SectionBy<ObjectType>?, applyFetchClauses: @escaping (_ fetchRequest:  Internals.CoreStoreFetchRequest<NSManagedObject>) -> Void, createAsynchronously: @escaping (LiveList<ObjectType>) -> Void) {

        self.init(
            context: dataStack.mainContext,
            from: from,
            sectionBy: sectionBy,
            applyFetchClauses: applyFetchClauses,
            createAsynchronously: createAsynchronously
        )
    }

    internal convenience init(unsafeTransaction: UnsafeDataTransaction, from: From<ObjectType>, sectionBy: SectionBy<ObjectType>?, applyFetchClauses: @escaping (_ fetchRequest:  Internals.CoreStoreFetchRequest<NSManagedObject>) -> Void) {

        self.init(
            context: unsafeTransaction.context,
            from: from,
            sectionBy: sectionBy,
            applyFetchClauses: applyFetchClauses,
            createAsynchronously: nil
        )
    }

    internal convenience init(unsafeTransaction: UnsafeDataTransaction, from: From<ObjectType>, sectionBy: SectionBy<ObjectType>?, applyFetchClauses: @escaping (_ fetchRequest:  Internals.CoreStoreFetchRequest<NSManagedObject>) -> Void, createAsynchronously: @escaping (LiveList<ObjectType>) -> Void) {

        self.init(
            context: unsafeTransaction.context,
            from: from,
            sectionBy: sectionBy,
            applyFetchClauses: applyFetchClauses,
            createAsynchronously: createAsynchronously
        )
    }

    internal func refetch(_ applyFetchClauses: @escaping (_ fetchRequest:  Internals.CoreStoreFetchRequest<NSManagedObject>) -> Void) {

        self.applyFetchClauses = applyFetchClauses

        DispatchQueue.main.async { [weak self] () -> Void in

            guard let `self` = self else {

                return
            }

            let (newFetchedResultsController, newFetchedResultsControllerDelegate) = Self.recreateFetchedResultsController(
                context: self.fetchedResultsController.managedObjectContext,
                from: self.from,
                sectionBy: self.sectionBy,
                applyFetchClauses: self.applyFetchClauses
            )
            newFetchedResultsControllerDelegate.handler = self

            do {

                try newFetchedResultsController.performFetchFromSpecifiedStores()
            }
            catch {

                // DataStack may have been deallocated
                return
            }
            (self.fetchedResultsController, self.fetchedResultsControllerDelegate) = (newFetchedResultsController, newFetchedResultsControllerDelegate)
        }
    }

    deinit {

        self.fetchedResultsControllerDelegate.fetchedResultsController = nil
        self.observers.removeAllObjects()
    }


    // MARK: FilePrivate

    fileprivate let rawObjectWillChange: Any?
    
    
    // MARK: Private

    private var fetchedResultsController: Internals.CoreStoreFetchedResultsController
    private var fetchedResultsControllerDelegate: Internals.FetchedDiffableDataSourceSnapshotDelegate
    private let sectionIndexTransformer: (_ sectionName: KeyPathString?) -> String?
    private var applyFetchClauses: (_ fetchRequest: Internals.CoreStoreFetchRequest<NSManagedObject>) -> Void
    private var observerForWillChangePersistentStore: Internals.NotificationObserver!
    private var observerForDidChangePersistentStore: Internals.NotificationObserver!

    private let from: From<ObjectType>
    private let sectionBy: SectionBy<ObjectType>?
    private lazy var observers: NSMapTable<AnyObject, Internals.Closure<LiveList<O>, Void>> = .weakToStrongObjects()

    private lazy var context: NSManagedObjectContext = self.fetchedResultsController.managedObjectContext

    private static func recreateFetchedResultsController(context: NSManagedObjectContext, from: From<ObjectType>, sectionBy: SectionBy<ObjectType>?, applyFetchClauses: @escaping (_ fetchRequest: Internals.CoreStoreFetchRequest<NSManagedObject>) -> Void) -> (controller: Internals.CoreStoreFetchedResultsController, delegate: Internals.FetchedDiffableDataSourceSnapshotDelegate) {

        let fetchRequest = Internals.CoreStoreFetchRequest<NSManagedObject>()
        fetchRequest.fetchLimit = 0
        fetchRequest.resultType = .managedObjectResultType
        fetchRequest.includesPendingChanges = false
        fetchRequest.shouldRefreshRefetchedObjects = true

        let fetchedResultsController = Internals.CoreStoreFetchedResultsController(
            context: context,
            fetchRequest: fetchRequest,
            from: from,
            sectionBy: sectionBy,
            applyFetchClauses: applyFetchClauses
        )

        let fetchedResultsControllerDelegate = Internals.FetchedDiffableDataSourceSnapshotDelegate()
        fetchedResultsControllerDelegate.fetchedResultsController = fetchedResultsController

        return (fetchedResultsController, fetchedResultsControllerDelegate)
    }

    private init(context: NSManagedObjectContext, from: From<ObjectType>, sectionBy: SectionBy<ObjectType>?, applyFetchClauses: @escaping (_ fetchRequest: Internals.CoreStoreFetchRequest<NSManagedObject>) -> Void, createAsynchronously: ((LiveList<ObjectType>) -> Void)?) {

        self.from = from
        self.sectionBy = sectionBy
        (self.fetchedResultsController, self.fetchedResultsControllerDelegate) = Self.recreateFetchedResultsController(
            context: context,
            from: from,
            sectionBy: sectionBy,
            applyFetchClauses: applyFetchClauses
        )

        if #available(iOS 13.0, tvOS 13.0, watchOS 6.0, macOS 10.15, *) {

            #if canImport(Combine)
            self.rawObjectWillChange = ObservableObjectPublisher()

            #else
            self.rawObjectWillChange = nil

            #endif
        }
        else {

            self.rawObjectWillChange = nil
        }

        if let sectionIndexTransformer = sectionBy?.sectionIndexTransformer {

            self.sectionIndexTransformer = sectionIndexTransformer
        }
        else {

            self.sectionIndexTransformer = { $0 }
        }
        self.applyFetchClauses = applyFetchClauses
        self.fetchedResultsControllerDelegate.handler = self

        try! self.fetchedResultsController.performFetchFromSpecifiedStores()
    }

    private func notifyObservers() {

        guard let enumerator = self.observers.objectEnumerator() else {

            return
        }
        for closure in enumerator {

            (closure as! Internals.Closure<LiveList<O>, Void>).invoke(with: self)
        }
    }
}


// MARK: - LiveList: FetchedDiffableDataSourceSnapshotHandler

extension LiveList: FetchedDiffableDataSourceSnapshotHandler {

    // MARK: FetchedDiffableDataSourceSnapshotHandler
    
//    @available(iOS 13.0, tvOS 13.0, watchOS 6.0, macOS 10.15, *)
//    internal func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChangeContentWith snapshot: NSDiffableDataSourceSnapshot<String, NSManagedObjectID>) {
//
//        self.snapshot = .init(
//            diffableSnapshot: snapshot,
//            context: controller.managedObjectContext
//        )
//    }

    internal func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChangeContentWith snapshot: Internals.DiffableDataSourceSnapshot) {

        self.snapshot = .init(
            diffableSnapshot: snapshot,
            context: controller.managedObjectContext
        )
    }
    
    internal func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, sectionIndexTitleForSectionName sectionName: String?) -> String? {
    
        return self.sectionIndexTransformer(sectionName)
    }
}


#if canImport(Combine)
import Combine

@available(iOS 13.0, tvOS 13.0, watchOS 6.0, macOS 10.15, *)
extension LiveList: ObservableObject {}

#endif

// MARK: - LiveList: LiveResult

extension LiveList: LiveResult {

    // MARK: ObservableObject

    #if canImport(Combine)

    @available(iOS 13.0, tvOS 13.0, watchOS 6.0, macOS 10.15, *)
    public var objectWillChange: ObservableObjectPublisher {

        return self.rawObjectWillChange! as! ObservableObjectPublisher
    }

    #endif

    public func willChange() {

        guard #available(iOS 13.0, tvOS 13.0, watchOS 6.0, macOS 10.15, *) else {

            return
        }
        #if canImport(Combine)

        #if canImport(SwiftUI)
        withAnimation {

            self.objectWillChange.send()
        }

        #endif

        self.objectWillChange.send()

        #endif
    }

    public func didChange() {

        // TODO:
    }
}
