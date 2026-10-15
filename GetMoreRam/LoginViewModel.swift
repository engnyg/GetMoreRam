//
//  LoginViewModel.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
import StosSign_API
import StosSign_Auth
import StosSign_Common

@MainActor
class LoginViewModel: ObservableObject {
    @Published var appleID = ""
    @Published var password = ""
    @Published var needVerificationCode = false
    @Published var verificationCode = ""
    @Published var loginModalShow = false
    @Published var teamSelectionShow = false
    @Published var isLoginInProgress = false
    @Published private(set) var isVerificationCodeSubmitting = false
    @Published var logs = ""
    @Published var availableTeams: [Team] = []
    
    private var verificationCodeHandler: ((String?) -> Void)?
    private var isAuthenticationCancellationRequested = false
    
    func submitVerificationCode() {
        guard !isVerificationCodeSubmitting,
              let verificationCodeHandler else { return }

        self.verificationCodeHandler = nil
        isVerificationCodeSubmitting = true
        verificationCodeHandler(verificationCode)
    }

    func cancelAuthentication() {
        guard isLoginInProgress else { return }

        isAuthenticationCancellationRequested = true

        let verificationCodeHandler = verificationCodeHandler
        self.verificationCodeHandler = nil
        needVerificationCode = false
        verificationCode = ""
        isVerificationCodeSubmitting = false

        verificationCodeHandler?(nil)
    }
    
    func authenticate() async throws -> Bool {
        if isLoginInProgress {
            return false
        }
        
        logs = ""
        isLoginInProgress = true
        isAuthenticationCancellationRequested = false
        
        func logging(text: String) {
            Task { @MainActor [weak self] in
                self?.logs.append("\(text)\n")
            }
        }
        
        AnisetteDataHelper.shared.loggingFunc = logging
        logging(text: "StosSign patches: 2fa-409, iloader-headers, anisette-resync")

        defer {
            verificationCodeHandler = nil
            appleID = ""
            password = ""
            needVerificationCode = false
            verificationCode = ""
            isLoginInProgress = false
            isVerificationCodeSubmitting = false
            isAuthenticationCancellationRequested = false
        }

        do {
            AnisetteDataHelper.shared.url = URL(string: DataManager.shared.model.anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines))
            var anisetteData = try await AnisetteDataHelper.shared.getAnisetteData()

            // Anisette one time passwords expire quickly, so the 2FA steps ask for fresh data
            Authentication.anisetteProvider = { try await AnisetteDataHelper.shared.getAnisetteData() }

            var resyncCount = 0
            var authResult: (Account, AppleAPISession)?
            while authResult == nil {
                do {
                    authResult = try await AppleAPI.shared.authenticate(appleID: appleID, password: password, anisetteData: anisetteData) { [weak self] completionHandler in
                        guard let self else {
                            completionHandler(nil)
                            return
                        }

                        self.prepareForVerification(using: completionHandler)
                    }
                } catch {
                    // Apple answers hsc 434 when the anisette needs to be resynced, then the sign in has to be retried
                    guard resyncCount < 2, let sim = Self.anisetteResyncSIM(from: error) else {
                        throw error
                    }
                    resyncCount += 1
                    logging(text: "Apple asked to resync the anisette, retrying")
                    anisetteData = try await AnisetteDataHelper.shared.resyncAnisetteData(sim: sim)
                }
            }
            guard let (account, session) = authResult else {
                throw AppleAPIError.unknown
            }

            guard !isAuthenticationCancellationRequested else {
                throw CancellationError()
            }

            logging(text: "Successfully signed in")

            DataManager.shared.model.account = account
            DataManager.shared.model.session = session
            Keychain.shared.appleIDEmailAddress = appleID
            Keychain.shared.appleIDPassword = password

            let teams = try await fetchTeams(for: account, session: session)
            logging(text: "Successfully fetched teams")
            availableTeams = teams

            return true
        } catch {
            if isAuthenticationCancellationRequested {
                throw CancellationError()
            }
            print(error)
            if !(error is CancellationError) {
                logging(text: "Sign in failed: \(error.detailedDescription)")
            }
            if case AppleAPIError.invalidAnisetteData = error {
                // Apple rejected our anisette, provision it again (with a new identifier) on the next try
                AnisetteDataHelper.shared.resetAnisetteState()
            }
            throw error
        }
    }

    private static let anisetteResyncPrefix = "anisette-resync:"

    /// The SIM from the hsc 434 error that the patched StosSign throws (see patches/stossign.patch)
    private static func anisetteResyncSIM(from error: Error) -> String? {
        guard case AppleAPIError.customError(let code, let message) = error,
              code == 434,
              message.hasPrefix(anisetteResyncPrefix) else { return nil }
        return String(message.dropFirst(anisetteResyncPrefix.count))
    }

    private func prepareForVerification(using handler: @escaping (String?) -> Void) {
        guard !isAuthenticationCancellationRequested else {
            handler(nil)
            return
        }

        verificationCodeHandler = handler
        verificationCode = ""
        needVerificationCode = true
        isVerificationCodeSubmitting = false
    }
    
    func fetchTeams(for account: Account, session: AppleAPISession) async throws -> [Team]
    {

        await DataManager.shared.model.refreshSessionAnisette()
        let fetchedTeams = try await AppleAPI.shared.fetchTeamsForAccount(account: account, session: session)
        guard !fetchedTeams.isEmpty else {
            throw "Unable to Fetch Team!"
        }
        
        return fetchedTeams
    }
}
