import Foundation
import PusherPlatform

public final class PCTestingTokenProvider: PPTokenProvider {

    public let userId: String
    let internalTokenProvider: PPHTTPEndpointTokenProvider
    public var logger: PPLogger? {
        willSet {
            self.internalTokenProvider.logger = newValue
        }
    }

    public init(userId: String, serviceId: String) {
        self.userId = userId

        let tokenProvider = PPHTTPEndpointTokenProvider(
            url: "https://chat-api-test-token-provider.herokuapp.com/token",
            requestInjector: { req -> PPHTTPEndpointTokenProviderRequest in
                req.addQueryItems(
                    [
                        URLQueryItem(name: "user_id", value: userId),
                        URLQueryItem(name: "instance", value: "v1:api-ceres:\(serviceId)"),
                    ]
                )
                return req
            }
        )

        self.internalTokenProvider = tokenProvider
    }

    public func fetchToken(completionHandler: @escaping (PPTokenProviderResult) -> Void) {
        self.internalTokenProvider.fetchToken(completionHandler: completionHandler)
    }
}
