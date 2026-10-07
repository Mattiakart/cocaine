// Render fixtures: --cloud-fixture providers | edit-s3 | edit-nextcloud | edit-sftp | edit-uploader | toast (memory only: the
// renders' settings are never the user's). Used by --render-panel (Settings → Island → Sharing, the shelf's actions) and
// --render-island (the link toast under the shelf).

import Foundation

enum CloudShareFixtures {
    static func apply(_ args: [String]) {
        guard AppDefaults.isolated, let i = args.firstIndex(of: "--cloud-fixture"), i + 1 < args.count else { return }
        let name = args[i + 1]
        let c = CloudShareCenter.shared
        var r2 = S3Preset.all.first { $0.id == "r2" }!.config()
        r2.title = "Cloudflare R2"; r2.settings["endpoint"] = "https://4f2c9a.r2.cloudflarestorage.com"; r2.settings["bucket"] = "shared-files"
        let nc = ShareProviderConfig(kind: .nextcloud, title: "Nextcloud", settings: ["server": "https://cloud.example.org", "user": "mattia", "folder": "Cocaine", "expiryDays": "7"])
        var sftp = ShareProviderConfig(kind: .sftp, title: "My server", settings: ["host": "files.example.org", "port": "22", "user": "deploy", "remoteDir": "public_html/s",
                                                                                 "publicBase": "https://example.org/s"])
        sftp.enabled = false
        let lb = ShareUploader.presets.first { $0.id == "litterbox" }!
        let up = ShareProviderConfig(kind: .uploader, title: lb.title, settings: ["template": lb.template, "extract": "url"])
        c.store.update { $0.providers = [r2, nc, sftp, up] }
        try? c.store.secrets.save(r2.id, ["accessKey": "AKIAFIXTURE", "secretKey": "fixture"])
        let now = Date()
        c.history.clear()
        c.history.add(ShareRecord(provider: sftp.id, providerTitle: sftp.title, kind: .sftp, name: "old-logo.svg", size: 4000, date: now.addingTimeInterval(-86400 * 9), expires: nil,
                                  link: "https://example.org/s/x", ref: "x", revoked: true))
        c.history.add(ShareRecord(provider: nc.id, providerTitle: nc.title, kind: .nextcloud, name: "Präsentation_final_v3.key", size: 9_000_000, date: now.addingTimeInterval(-86400 * 8),
                                  expires: now.addingTimeInterval(-86400), link: "https://cloud.example.org/s/abc", ref: "a", shareID: "4"))
        let fresh = ShareRecord(provider: r2.id, providerTitle: r2.title, kind: .s3, name: "Quarterly report 2026.pdf", size: 120_000, date: now.addingTimeInterval(-600),
                                expires: now.addingTimeInterval(86400 - 600), link: "https://4f2c9a.r2.cloudflarestorage.com/shared-files/k?X-Amz-Signature=fixture", ref: "k")
        c.history.add(fresh)
        // the shelf's actions, with a webhook, keys and a chain (Settings → Island → Shelf)
        var hook = ShelfAction(name: "Send to hooks.example.org", kind: .webhook, target: "https://hooks.example.org/in", hook: WebhookSpec()); hook.key = 1
        var gif = ShelfAction(name: "Make GIF", kind: .shortcut, target: "Make GIF"); gif.key = 2
        hook.then = gif.id
        ShelfConfigStore.shared.update { $0.actions = [hook, gif] }
        switch name {
        case "toast": c.show(fresh)
        case "edit-s3": CloudEditor.fixture = (r2, ["accessKey", "secretKey"], S3Preset.all.first { $0.id == "r2" }?.hint)
        case "edit-nextcloud": CloudEditor.fixture = (nc, [], nil)
        case "edit-sftp": CloudEditor.fixture = (sftp, [], L("Keys only: your ssh-agent or a key file. The server must already be in ~/.ssh/known_hosts (connect once with ssh)."))
        case "edit-uploader":
            var u = up; u.settings["extract"] = "json"; u.settings["pattern"] = "files[0].url"
            CloudEditor.fixture = (u, ["headers"], lb.warning)
        default: break
        }
    }
}
