import Foundation
import SwiftSignalKit
import Postbox
import TelegramApi

public final class NotificationSoundList: Equatable, Codable {
    public final class NotificationSound: Equatable, Codable {
        private enum CodingKeys: String, CodingKey {
            case file
        }
        
        public let file: TelegramMediaFile
        
        public init(
            file: TelegramMediaFile
        ) {
            self.file = file
        }
        
        public static func ==(lhs: NotificationSound, rhs: NotificationSound) -> Bool {
            if lhs.file != rhs.file {
                return false
            }
            return true
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            let fileData = try container.decode(AdaptedPostboxDecoder.RawObjectData.self, forKey: .file)
            self.file = TelegramMediaFile(decoder: PostboxDecoder(buffer: MemoryBuffer(data: fileData.data)))
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(PostboxEncoder().encodeObjectToRawData(self.file), forKey: .file)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case hash
        case sounds
    }
    
    public let hash: Int64
    public let sounds: [NotificationSound]
    
    public init(
        hash: Int64,
        sounds: [NotificationSound]
    ) {
        self.hash = hash
        self.sounds = sounds
    }
    
    public static func ==(lhs: NotificationSoundList, rhs: NotificationSoundList) -> Bool {
        if lhs.hash != rhs.hash {
            return false
        }
        if lhs.sounds != rhs.sounds {
            return false
        }
        return true
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.hash = try container.decode(Int64.self, forKey: .hash)
        self.sounds = try container.decode([NotificationSound].self, forKey: .sounds)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(self.hash, forKey: .hash)
        try container.encode(self.sounds, forKey: .sounds)
    }
}

private extension NotificationSoundList.NotificationSound {
    convenience init?(apiDocument: Api.Document) {
        guard let file = telegramMediaFileFromApiDocument(apiDocument) else {
            return nil
        }
        self.init(file: file)
    }
}

func _internal_cachedNotificationSoundList(postbox: Postbox) -> Signal<NotificationSoundList?, NoError> {
    return postbox.transaction { transaction -> NotificationSoundList? in
        return _internal_cachedNotificationSoundList(transaction: transaction)
    }
}

func _internal_cachedNotificationSoundListCacheKey() -> ItemCacheEntryId {
    let key = ValueBoxKey(length: 8)
    key.setInt64(0, value: 0)
    
    return ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.notificationSoundList, key: key)
}

func _internal_cachedNotificationSoundList(transaction: Transaction) -> NotificationSoundList? {
    let cached = transaction.retrieveItemCacheEntry(id: _internal_cachedNotificationSoundListCacheKey())?.get(NotificationSoundList.self)
    if let cached = cached {
        return cached
    } else {
        return nil
    }
}

func _internal_setCachedNotificationSoundList(transaction: Transaction, notificationSoundList: NotificationSoundList) {
    if let entry = CodableEntry(notificationSoundList) {
        transaction.putItemCacheEntry(id: _internal_cachedNotificationSoundListCacheKey(), entry: entry, collectionSpec: ItemCacheCollectionSpec(lowWaterItemCount: 10, highWaterItemCount: 10))
    }
}

private func pollNotificationSoundList(postbox: Postbox, network: Network) -> Signal<Never, NoError> {
    return Signal<Never, NoError> { subscriber in
        let signal: Signal<Never, NoError> = _internal_cachedNotificationSoundList(postbox: postbox)
        |> mapToSignal { current in
            return (network.request(Api.functions.account.getSavedRingtones(hash: current?.hash ?? 0))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.account.SavedRingtones?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Never, NoError> in
                return postbox.transaction { transaction -> Signal<Never, NoError> in
                    guard let result = result else {
                        return .complete()
                    }
                    switch result {
                    case let .savedRingtones(hash, ringtones):
                        let notificationSoundList = NotificationSoundList(
                            hash: hash,
                            sounds: ringtones.compactMap(NotificationSoundList.NotificationSound.init(apiDocument:))
                        )
                        _internal_setCachedNotificationSoundList(transaction: transaction, notificationSoundList: notificationSoundList)
                    case .savedRingtonesNotModified:
                        break
                    }
                    
                    var signals: [Signal<Never, NoError>] = []
                    
                    if let notificationSoundList = _internal_cachedNotificationSoundList(transaction: transaction) {
                        var resources: [MediaResource] = []
                        
                        for sound in notificationSoundList.sounds {
                            resources.append(sound.file.resource)
                        }
                        
                        for resource in resources {
                            signals.append(
                                fetchedMediaResource(mediaBox: postbox.mediaBox, reference: .standalone(resource: resource))
                                |> ignoreValues
                                |> `catch` { _ -> Signal<Never, NoError> in
                                    return .complete()
                                }
                            )
                        }
                    }
                    
                    return combineLatest(signals)
                    |> ignoreValues
                }
                |> switchToLatest
            })
        }
                
        return signal.start(completed: {
            subscriber.putCompletion()
        })
    }
}

func managedSynchronizeNotificationSoundList(postbox: Postbox, network: Network) -> Signal<Never, NoError> {
    let poll = pollNotificationSoundList(postbox: postbox, network: network)
    
    return (
        poll
        |> then(
            .complete()
            |> suspendAwareDelay(1.0 * 60.0 * 60.0, queue: Queue.concurrentDefaultQueue())
        )
    )
    |> restart
}

func _internal_saveNotificationSound(account: Account, file: TelegramMediaFile) -> Signal<Never, UploadNotificationSoundError> {
    guard let resource = file.resource as? CloudDocumentMediaResource else {
        return .fail(.generic)
    }
    return account.network.request(Api.functions.account.saveRingtone(id: .inputDocument(id: resource.fileId, accessHash: resource.accessHash, fileReference: Buffer(data: resource.fileReference)), unsave: .boolFalse))
    |> mapError { _ -> UploadNotificationSoundError in
        return .generic
    }
    |> mapToSignal { _ -> Signal<Never, UploadNotificationSoundError> in
        return pollNotificationSoundList(postbox: account.postbox, network: account.network)
        |> castError(UploadNotificationSoundError.self)
    }
}

public enum UploadNotificationSoundError {
    case generic
}

func _internal_uploadNotificationSound(account: Account, title: String, data: Data) -> Signal<NotificationSoundList.NotificationSound, UploadNotificationSoundError> {
    return multipartUpload(network: account.network, postbox: account.postbox, source: .data(data), encrypt: false, tag: nil, hintFileSize: data.count, hintFileIsLarge: false, forceNoBigParts: true, useLargerParts: false, increaseParallelParts: false, useMultiplexedRequests: false, useCompression: false)
    |> mapError { _ -> UploadNotificationSoundError in
        return .generic
    }
    |> mapToSignal { value -> Signal<NotificationSoundList.NotificationSound, UploadNotificationSoundError> in
        switch value {
        case let .inputFile(file):
            return account.network.request(Api.functions.account.uploadRingtone(file: file, fileName: title, mimeType: "audio/mpeg"))
            |> mapError { _ -> UploadNotificationSoundError in
                return .generic
            }
            |> mapToSignal { result -> Signal<NotificationSoundList.NotificationSound, UploadNotificationSoundError> in
                guard let file = telegramMediaFileFromApiDocument(result) else {
                    return .fail(.generic)
                }
                return account.postbox.transaction { transaction -> NotificationSoundList.NotificationSound in
                    let item = NotificationSoundList.NotificationSound(file: file)
                    
                    account.postbox.mediaBox.storeResourceData(file.resource.id, data: data, synchronous: true)
                    
                    let notificationSoundList = _internal_cachedNotificationSoundList(transaction: transaction) ?? NotificationSoundList(hash: 0, sounds: [])
                    let updatedNotificationSoundList = NotificationSoundList(hash: notificationSoundList.hash, sounds: [item] + notificationSoundList.sounds)
                    _internal_setCachedNotificationSoundList(transaction: transaction, notificationSoundList: updatedNotificationSoundList)
                    
                    return item
                }
                |> castError(UploadNotificationSoundError.self)
            }
        default:
            return .never()
        }
    }
}