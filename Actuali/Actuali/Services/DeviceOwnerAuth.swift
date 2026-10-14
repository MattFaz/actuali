import LocalAuthentication

/// Face ID / Touch ID / Optic ID with the device passcode as fallback, for the
/// app lock (GH #717).
enum DeviceOwnerAuth {
    /// Whether the device has a passcode, the floor `.deviceOwnerAuthentication`
    /// needs. Without one there is nothing to lock with.
    nonisolated static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// The biometry the system prompt will use; `.none` means passcode only.
    nonisolated static var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType
    }

    /// True once the user authenticates. A device that lost its passcode since
    /// the lock was turned on also passes: otherwise the lock could never be
    /// opened again, and without a passcode the phone itself is unprotected.
    nonisolated static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return await (try? context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
