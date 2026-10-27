import Foundation

protocol DeviceProvider {
    var kind: DeviceProviderKind { get }
    func scan() -> ProviderOutcome
}
