import Foundation
import PusherPlatform

class PCBasicMessageEnricher {
    public let userStore: PCGlobalUserStore
    public let room: PCRoom
    let logger: PPLogger

    fileprivate var completionOrderList: [Int] = []
    fileprivate var messageIdToCompletionHandlers: [Int: (PCMessage?, Error?) -> Void] = [:]
    fileprivate var enrichedMessagesAwaitingCompletionCalls: [Int: PCMessageEnrichmentResult] = [:]

    // TODO: What should the QoS be here?
    fileprivate let messageEnrichmentQueue = DispatchQueue(label: "com.pusher.chat-api.message-enrichment")

    fileprivate var userIdsBeingRetrieved: [String] = []
    fileprivate var userIdsToBasicMessageIds: [String: [Int]] = [:]
    fileprivate var messagesAwaitingEnrichmentDependentOnUserRetrieval: [Int: PCBasicMessage] = [:]

    fileprivate let userRetrievalQueue = DispatchQueue(label: "com.pusher.chat-api.user-retrieval")

    init(userStore: PCGlobalUserStore, room: PCRoom, logger: PPLogger) {
        self.userStore = userStore
        self.room = room
        self.logger = logger
    }

    func enrich(_ basicMessage: PCBasicMessage, completionHandler: @escaping (PCMessage?, Error?) -> Void) {
        let basicMessageId = basicMessage.id
        let basicMessageSenderId = basicMessage.senderId

        messageEnrichmentQueue.async(flags: .barrier) {
            self.completionOrderList.append(basicMessageId)
            self.messageIdToCompletionHandlers[basicMessageId] = completionHandler
        }

        userRetrievalQueue.async(flags: .barrier) {
            if self.userIdsToBasicMessageIds[basicMessageSenderId] == nil {
                self.userIdsToBasicMessageIds[basicMessageSenderId] = [basicMessageId]
            } else {
                self.userIdsToBasicMessageIds[basicMessageSenderId]!.append(basicMessageId)
            }

            self.messagesAwaitingEnrichmentDependentOnUserRetrieval[basicMessageId] = basicMessage

            if self.userIdsBeingRetrieved.contains(basicMessageSenderId) {
                return
            } else {
                self.userIdsBeingRetrieved.append(basicMessageSenderId)
            }

            self.userStore.user(id: basicMessage.senderId) { user, err in
                guard let user = user, err == nil else {
                    self.logger.log(
                        "Unable to find user with id \(basicMessage.senderId), associated with message \(basicMessageId). Error: \(err!.localizedDescription)",
                        logLevel: .debug
                    )
                    self.callCompletionHandlersForEnrichedMessagesWithIdsLessThanOrEqualTo(id: basicMessageId, result: .error(err!))
                    return
                }

                self.userRetrievalQueue.async(flags: .barrier) {
                    guard let basicMessageIds = self.userIdsToBasicMessageIds[basicMessageSenderId] else {
                        // TODO: Log
                        return
                    }

                    let basicMessages = basicMessageIds.flatMap { bmId -> PCBasicMessage? in
                        return self.messagesAwaitingEnrichmentDependentOnUserRetrieval[bmId]
                    }

                    self.enrichMessagesWithUser(user, messages: basicMessages)

                    if let indexToRemove = self.userIdsBeingRetrieved.index(of: basicMessageSenderId) {
                        self.userIdsBeingRetrieved.remove(at: indexToRemove)
                    }
                }
            }
        }
    }

    fileprivate func enrichMessagesWithUser(_ user: PCUser, messages: [PCBasicMessage]) {
        messages.forEach { basicMessage in
            let message = PCMessage(
                id: basicMessage.id,
                text: basicMessage.text,
                createdAt: basicMessage.createdAt,
                updatedAt: basicMessage.updatedAt,
                sender: user,
                room: self.room
            )
            self.callCompletionHandlersForEnrichedMessagesWithIdsLessThanOrEqualTo(id: basicMessage.id, result: .success(message))
        }
    }

    fileprivate func callCompletionHandlersForEnrichedMessagesWithIdsLessThanOrEqualTo(id: Int, result: PCMessageEnrichmentResult) {

        // TODO: There may well be ways to make this faster
        self.messageEnrichmentQueue.async(flags: .barrier) {
            guard let nextIdToComplete = self.completionOrderList.first else {
                self.logger.log("Message with id \(id) enriched but message enricher doesn't know about enriching it", logLevel: .debug)
                return
            }

            self.enrichedMessagesAwaitingCompletionCalls[id] = result

             guard id == nextIdToComplete else {
                // If the message id received isn't the next to have its completionHandler called
                // then return as we've already stored the result so it can be used later
                return
            }

            repeat {
                let messageId = self.completionOrderList.first!

                guard let completionHandler = self.messageIdToCompletionHandlers[messageId] else {
                    self.logger.log("Completion handler not stored for message id \(messageId)", logLevel: .debug)
                    return
                }

                guard let result = self.enrichedMessagesAwaitingCompletionCalls[messageId] else {
                    self.logger.log("Enrichment result not stored for message id \(messageId)", logLevel: .debug)
                    return
                }

                switch result {
                case .success(let message):
                    completionHandler(message, nil)
                case .error(let err):
                    completionHandler(nil, err)
                }

                self.completionOrderList.removeFirst()
                self.messageIdToCompletionHandlers.removeValue(forKey: messageId)
                self.enrichedMessagesAwaitingCompletionCalls.removeValue(forKey: messageId)
            } while self.completionOrderList.first != nil && self.enrichedMessagesAwaitingCompletionCalls[self.completionOrderList.first!] != nil
        }
    }
}

public enum PCMessageEnrichmentResult {
    case success(PCMessage)
    case error(Error)
}
