# Privacy

Typemore processes text when you actively trigger rewriting or click the connection trial in settings. For rewriting in another app, this includes the selected text or the target text around the cursor and necessary surrounding context.

The text is sent directly to the model service selected in settings. API connections use the configured provider endpoint. ChatGPT account connections use the official Sign in with ChatGPT flow and the public Responses API, with `store: false` and streaming enabled. The OAuth request asks for account identity and permission to use the user's ChatGPT plan. Users can manage access and limits in ChatGPT settings.

Doubao connections invoke the separately installed official Doubao CLI. Its login credentials and task history are managed by Doubao under its own terms and privacy rules. Typemore requests approval for tool operations and uses a temporary empty task directory for rewriting. Model providers and CLI services may retain data under their own policies.

Typemore does not run its own model backend, collect analytics, or bundle user credentials. API keys and ChatGPT OAuth credentials are stored in macOS Keychain. Non-secret connection settings, writing preferences, and shortcuts are stored locally in Application Support under Typemore/Public. Legacy settings are read for migration and kept unchanged. A Keychain write failure is reported and does not mark the configuration as saved.

When Keychain authentication fails, users can choose to recover the connection in the app. After confirmation, macOS locks and unlocks the default keychain and presents its own password verification dialog. Other apps may also request an unlock. If verification is canceled, the keychain remains locked until it is unlocked again. Typemore does not receive or store the Mac login password. After verification, the app retries the failed operation and checks whether the saved credentials are accessible.

Typemore prefers the macOS Accessibility API to read and replace text. Where required, it temporarily uses the clipboard to copy or paste, then restores the previous clipboard contents. Third-party clipboard managers may record intermediate content. Avoid triggering Typemore in sensitive input fields.
