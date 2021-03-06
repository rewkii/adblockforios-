/*
 * This file is part of Adblock Plus <https://adblockplus.org/>,
 * Copyright (C) 2006-present eyeo GmbH
 *
 * Adblock Plus is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 3 as
 * published by the Free Software Foundation.
 *
 * Adblock Plus is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Adblock Plus.  If not, see <http://www.gnu.org/licenses/>.
 */

import libadblockplus_ios
import RxCocoa
import RxSwift

/// Handle filter list updating.
///
/// This replaces the former Objective-C implementation of AdblockPlusExtras.
///
/// It makes use of struct FilterList to represent a filter list. Therefore, the **Swift model
/// struct should always be used when interacting with this class.**
///
/// Filter lists on the Objective-C side are [String :[String: Any]] or a dictionary of
/// dictionaries.
class FilterListsUpdater: AdblockPlusShared,
                          URLSessionDownloadDelegate {
    let updatingKey = "updatingGroupIdentifier"

    /// Bag for reload operations.
    var reloadBag: DisposeBag! = DisposeBag()

    /// Bag for download operations.
    var downloadBag: DisposeBag! = DisposeBag()

    /// For download tasks.
    var backgroundSession: URLSession!

    /// Filter list download tasks keyed by task ID.
    var downloadTasksByID = [UIBackgroundTaskIdentifier: URLSessionTask]()

    /// Download events keyed by task ID.
    var downloadEvents = [UIBackgroundTaskIdentifier: BehaviorSubject<DownloadEvent>]()

    /// This identifier is incremented every time filter lists are updated.
    /// See updateFilterLists:withNames:userTriggered.
    @objc var updatingGroupIdentifier = 0

    /// Handles reloading of the content blocker.
    var cbManager: ContentBlockerManagerProtocol!

    /// Reference to active ABPManager that must not be nil. Without this reference, accessing the
    /// ABP Manager shared instance will be circular since the ABP Manager has a strong reference
    /// to the Filter List updater and makes an updater in its init.
    weak var abpManager: ABPManager!

    /// Setter used during legacy refactoring.
    var setLegacyReloading: (Bool) -> Void

    /// Setter used during legacy refactoring.
    var setLegacyPerformingActivityTest: (Bool) -> Void

    /// Performs content blocking operations.
    var safariCB: SafariContentBlocker!

    /// Construct a FilterListUpdater. Process running tasks and add a reloading observer.
    /// - Parameter abpManager: Because the ABPManager initializes an instance of this class in
    /// its init, the shared instance of ABPManager cannot be used within the init of this class
    /// without forming a circular reference. Therefore, a reference to the ABP Manager is passed
    /// in and stored as a property.
    init(abpManager: ABPManager) {
        setLegacyReloading = abpManager.setLegacyReloading
        setLegacyPerformingActivityTest = abpManager.setLegacyPerformingActivityTest
        safariCB = SafariContentBlocker(reloadingSetter: setLegacyReloading,
                                        performingActivityTestSetter: setLegacyPerformingActivityTest)
        super.init()
        cbManager = ContentBlockerManager()
        self.abpManager = abpManager
        backgroundSession = newBackgroundSession()
        removeUpdatingGroupID()

        // Turn off the error dialog during init. If filter list updating is interrupted after this
        // the error dialog will be shown.
        abpManager.adblockPlus.needsDisplayErrorDialog = false

        processRunningTasks()
    }

    // ------------------------------------------------------------
    // MARK: - URL Session -
    // ------------------------------------------------------------

    /// Make the URL session used for downloading filter lists.
    func newBackgroundSession() -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: backgroundSessionConfigurationIdentifier())
        return URLSession(configuration: config,
                          delegate: self,
                          delegateQueue: .main)
    }

    /// Remove the updating state key from a filter list.
    private func removeUpdatingGroupID() {
        let lists = abpManager.filterLists()
        var newLists = [libadblockplus_ios.FilterList]()
        for var list in lists {
            list.updatingGroupIdentifier = nil
            newLists.append(list)
        }
        abpManager.saveFilterLists(newLists)
    }

    /// Update the download tasks for all filter lists. If there is a task to complete, save it as
    /// a new download task. If there was a previous matching task matched by list URL and task
    /// identifier, it will be cancelled.
    private func processRunningTasks() {
        backgroundSession.getAllTasks(completionHandler: { tasks in
            guard let lists = self.abpManager?.filterLists() else { return }
            var listsToRemoveUpdatingFrom = [FilterListName]()
            for list in lists where list.name != nil {
                listsToRemoveUpdatingFrom.append(list.name!)
            }

            // Remove filter lists whose tasks are still running.
            for task in tasks {
                var found = false
                var listIndex = 0
                for list in lists {
                    if let url = task.originalRequest?.url?.absoluteString {
                        if url == list.source &&
                           task.taskIdentifier == list.taskIdentifier {
                            self.downloadTasksByID[task.taskIdentifier] = task
                            var nameIndex = 0
                            for name in listsToRemoveUpdatingFrom {
                                if name == list.name {
                                    listsToRemoveUpdatingFrom.remove(at: nameIndex)
                                    break
                                }
                                nameIndex += 1
                            }
                        } else {
                            // If a task was interrupted, then it is cancelled here. This handles
                            // the case where the app crashes or is forced to quit during a download
                            // task. The user receives an alert and is able to redo what had
                            // previously failed.
                            task.cancel()
                        }
                        found = true
                        break
                    }
                    listIndex += 1
                } // End for list
                if !found {
                    task.cancel()
                }
            } // End for task

            // Set updating to false for lists that don't have tasks.
            self.abpManager?.setNotUpdating(forNames: listsToRemoveUpdatingFrom)
        })
    }

    /// Time limit for a download operation.
    /// - Returns: Time interval according to background state.
    func downloadLimit() -> TimeInterval {
        let mgr = self.abpManager
        if mgr?.inBackground.value == true {
            return GlobalConstants.backgroundOperationLimit
        }
        return GlobalConstants.foregroundOperationLimit
    }

    /// A filter list download task is created. An entry in the download tasks dictionary is
    /// created for the task.
    /// - Parameter filterList: A filter List struct.
    /// - Returns: The download task.
    func filterListDownload(for filterList: libadblockplus_ios.FilterList) -> Observable<URLSessionDownloadTask> {
        return Observable.create { observer in
            guard let urlString = filterList.source,
                  let url = URL(string: urlString),
                  var components = URLComponents(string: url.absoluteString)
            else {
                observer.onError(ABPDownloadTaskError.failedToMakeDownloadTask)
                return Disposables.create()
            }
            components.queryItems = FilterListDownloadData(with: filterList).queryItems
            components.encodePlusSign()
            if let newURL = components.url {
                let task = self.backgroundSession.downloadTask(with: newURL)
                self.downloadTasksByID[task.taskIdentifier] = task
                observer.onNext(task)
                observer.onCompleted()
            } else {
                observer.onError(ABPDownloadTaskError.failedToMakeDownloadTask)
            }
            return Disposables.create()
        }
    }

    // ------------------------------------------------------------
    // MARK: - Filter Lists -
    // ------------------------------------------------------------

    /// An observable with tasks to update each named filter list.
    /// Tasks are not started.
    /// - Parameters:
    ///   - names: Array of names of filter lists to update.
    ///   - userTriggered: User triggered flag.
    /// - Returns: Stream of FilterListUpdate model structs.
    func updateMake(with names: [FilterListName],
                    userTriggered: Bool) -> Observable<FilterListUpdate> {
        return Observable.from(names).concatMap({ name -> Observable<FilterListUpdate> in
            return self.updateFilterList(with: name,
                                         userTriggered: userTriggered)
        })
    }

    /// Tasks are started here and observed for completion. Download operations are limited by the
    /// download limit. The observable is disposed when the limit is exceeded.
    /// - Parameter update: A filter list update model struct.
    /// - Returns: The update that was completed.
    func updateWait(for update: FilterListUpdate) -> Observable<FilterListUpdate> {
        let taskID = update.task.taskIdentifier
        self.downloadEvents[taskID] = BehaviorSubject<DownloadEvent>(value: DownloadEvent())
        update.task.resume()

        // The subscribe is wrapped in an Observable to use timeout()
        return Observable.create { observer in
            return self.downloadEvents[taskID]!
                .filter { event -> Bool in
                    return event.didFinishDownloading == true &&
                           event.errorWritten == true
                }.subscribe(onNext: { _ in
                    self.safariCB.reloadContentBlocker { error in
                        if error == nil {
                            observer.onNext(update)
                            observer.onCompleted()
                        } else {
                            observer.onError(error!)
                        }
                    }
                }, onDisposed: {
                    self.cleanupUpdate(update)
                })
        }.timeout(downloadLimit(),
                  scheduler: MainScheduler.asyncInstance)
    }

    /// Update filter lists with statuses of tasks running while the app is in the background.
    /// Update should only occur if the filter list is considered to be expired.
    /// - Parameters:
    ///   - names: Array of filter list names.
    ///   - userTriggered: True if initiated by a user.
    ///   - completion: Nonrequired closure that is called when all downloads are complete if
    ///   downloading happens.
    @objc
    func updateFilterLists(withNames names: [FilterListName],
                           userTriggered: Bool,
                           completion: ((Error?) -> Void)? = nil) {
        downloadBag = DisposeBag()
        updateMake(with: names,
                   userTriggered: userTriggered)
            .concatMap { update -> Observable<FilterListUpdate> in
                return self.updateWait(for: update)
            }.subscribe(onNext: { update in
                do {
                    try self.internallyUpdate(with: update)
                } catch {
                    // Internal state will be corrupt if an error occurs with the internal update. This is not
                    // a fatal condition as the state is continually updated as filter lists expire.
                }
                completion?(nil)
            }, onError: { error in
                completion?(error)
            }).disposed(by: downloadBag)
    }

    /// This is the private function for downloading an updated filter list. The last update date is
    /// changed here.
    /// - Parameters:
    ///   - name: Filter list name.
    ///   - userTriggered: True if initiated by the user.
    /// - Returns: Observable of the filter list name for confirmation.
    fileprivate func updateFilterList(with name: FilterListName,
                                      userTriggered: Bool) -> Observable<FilterListUpdate> {
        self.updatingGroupIdentifier += 1
        // Make a filter list that exists on the Objective-C side.
        let listsKey = "AdblockPlusFilterListsVersion2"
        let details = ABPManager.sharedInstance().adblockPlus.adblockPlusDetails
        let root = details.value(forKey: listsKey) as? [String: Any]
        guard var filterList = FilterList(matching: name,
                                          root: root)
        else {
            return Observable.create { observer in
                observer.onError(ABPFilterListError.invalidData)
                return Disposables.create()
            }
        }
        filterList.lastUpdate = Date()
        return self.filterListDownload(for: filterList).flatMap { task -> Observable<FilterListUpdate> in
            let update = FilterListUpdate(filterList: filterList,
                                          task: task,
                                          userTriggered: userTriggered)
            return Observable.create { observer in
                observer.onNext(update)
                observer.onCompleted()
                return Disposables.create()
            }
        }
    }

    /// Clean up memory for
    /// * Download events
    /// * Download tasks
    /// - Parameter update: A filter list update model struct.
    func cleanupUpdate(_ update: FilterListUpdate) {
        update.task.cancel()
        downloadTasksByID[update.task.taskIdentifier] = nil
    }

    /// Update filter list with a new download count.
    /// - Parameter filterList: A filter list.
    func updateSuccessfulDownloadCount(for filterList: inout libadblockplus_ios.FilterList) {
        if filterList.downloadCount != nil {
            filterList.downloadCount! += 1
        } else {
            filterList.downloadCount = 1
        }
    }

    /// Examine the current filter lists and return an array of filter list names that are
    /// outdated.
    /// - Returns: Array of filter lists that are outdated.
    func outdatedFilterListNames() -> [FilterListName] {
        var outdated = [FilterListName]()
        for key in filterLists.keys {
            if let uwList = FilterList(named: key,
                                       fromDictionary: filterLists[key]) {
                if uwList.expired() {
                    outdated.append(key)
                }
            }
        }
        return outdated
    }

    /// Set whether acceptable ads will be enabled or not. The content blocker filter lists are
    /// reloaded after a state change triggered by the user. Enabling acceptable ads will also
    /// enable the content blocker if it is disabled.
    /// - Parameter enabled: True if acceptable ads are enabled.
    @objc
    func changeAcceptableAds(enabled: Bool) {
        super.enabled = enabled
        safariCB.reloadContentBlocker(after: { [weak self] in
            if let names = self?.outdatedFilterListNames() {
                self?.updateFilterLists(withNames: names,
                                        userTriggered: false)
            }
        })
    }

    /// Set whether the default filter list be used or not. The content blocker filter lists are
    /// reloaded after the state change.
    /// - Parameter enabled: True if the default filter list is enabled.
    func setDefaultFilterListEnabled(enabled: Bool) {
        super.defaultFilterListEnabled = enabled
        safariCB.reloadContentBlocker { _ in
            self.updateFilterLists(withNames: self.outdatedFilterListNames(),
                                   userTriggered: false)
        }
    }
}
