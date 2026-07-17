import Foundation

enum SkinCSSBuilder {
    static let styleID = "gptswitch-codex-skin-style"
    static let revision = "2"

    static func statusValue(themeID: String) -> String {
        "\(themeID)@\(revision)"
    }

    static func build(theme: SkinTheme, palette: SkinPalette, imageData: Data) -> String {
        let imageURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let darkPalette = palette.darkModeVariant()
        let darkOverlayOpacity = theme.isDark ? 0.12 : 0.34
        return """
        :root {
          --gpts-accent: \(palette.accent);
          --gpts-secondary: \(palette.secondary);
          --gpts-surface: \(palette.surface);
          --gpts-text: \(palette.text);
          --gpts-image-overlay: transparent;
          --color-background-surface: color-mix(in srgb, var(--gpts-surface) 90%, transparent) !important;
          --color-background-panel: color-mix(in srgb, var(--gpts-surface) 94%, transparent) !important;
          --color-background-button-primary: var(--gpts-accent) !important;
          --color-text-foreground: var(--gpts-text) !important;
          --color-border: color-mix(in srgb, var(--gpts-accent) 42%, transparent) !important;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --gpts-accent: \(darkPalette.accent);
            --gpts-secondary: \(darkPalette.secondary);
            --gpts-surface: \(darkPalette.surface);
            --gpts-text: \(darkPalette.text);
            --gpts-image-overlay: rgb(0 0 0 / \(darkOverlayOpacity));
          }
        }
        html[data-gptswitch-skin] { color-scheme: light dark; }
        html[data-gptswitch-skin] body, html[data-gptswitch-skin] #root { color: var(--gpts-text) !important; }
        html[data-gptswitch-skin] #root {
          background:
            linear-gradient(90deg, color-mix(in srgb, var(--gpts-surface) 94%, transparent) 0 22%, transparent 48%),
            linear-gradient(180deg, transparent 0 42%, color-mix(in srgb, var(--gpts-surface) 76%, transparent) 100%),
            linear-gradient(var(--gpts-image-overlay), var(--gpts-image-overlay)),
            url("\(imageURL)") right center / cover no-repeat fixed !important;
        }
        html[data-gptswitch-skin] .app-shell-left-panel {
          background: color-mix(in srgb, var(--gpts-surface) 88%, transparent) !important;
          border-right: 1px solid color-mix(in srgb, var(--gpts-accent) 42%, transparent) !important;
          backdrop-filter: blur(20px) saturate(1.12);
        }
        html[data-gptswitch-skin] .main-surface,
        html[data-gptswitch-skin] .browser-main-surface {
          background: linear-gradient(180deg, transparent 0 38%, color-mix(in srgb, var(--gpts-surface) 72%, transparent) 100%) !important;
        }
        html[data-gptswitch-skin] .composer-surface-chrome,
        html[data-gptswitch-skin] [data-user-message-bubble],
        html[data-gptswitch-skin] [data-local-conversation-final-assistant],
        html[data-gptswitch-skin] [data-codex-approval-surface] {
          color: var(--gpts-text) !important;
          border-color: color-mix(in srgb, var(--gpts-accent) 45%, transparent) !important;
          background: color-mix(in srgb, var(--gpts-surface) 88%, transparent) !important;
          box-shadow: 0 8px 24px color-mix(in srgb, var(--gpts-accent) 16%, transparent) !important;
          backdrop-filter: blur(18px) saturate(1.08);
        }
        html[data-gptswitch-skin] [data-app-action-sidebar-thread-active="true"] {
          background: linear-gradient(90deg, color-mix(in srgb, var(--gpts-accent) 22%, transparent), color-mix(in srgb, var(--gpts-secondary) 16%, transparent)) !important;
        }
        """
    }

    static func installExpression(themeID: String, css: String) -> String {
        """
        (() => {
          const id = \(jsLiteral(styleID));
          let style = document.getElementById(id);
          if (!style) { style = document.createElement('style'); style.id = id; document.head.appendChild(style); }
          style.textContent = \(jsLiteral(css));
          document.documentElement.dataset.gptswitchSkin = \(jsLiteral(themeID));
          document.documentElement.dataset.gptswitchSkinRevision = \(jsLiteral(revision));
          window.__gptSwitchSkin = { themeId: \(jsLiteral(themeID)), revision: \(jsLiteral(revision)), dispose() {
            document.getElementById(id)?.remove();
            delete document.documentElement.dataset.gptswitchSkin;
            delete document.documentElement.dataset.gptswitchSkinRevision;
            delete window.__gptSwitchSkin;
          }};
          return \(jsLiteral(statusValue(themeID: themeID)));
        })()
        """
    }

    static let removeExpression = """
    (() => {
      try { window.__gptSwitchSkin?.dispose?.(); } catch (_) {}
      document.getElementById(\(jsLiteral(styleID)))?.remove();
      delete document.documentElement.dataset.gptswitchSkin;
      delete document.documentElement.dataset.gptswitchSkinRevision;
      try { delete window.__gptSwitchSkin; } catch (_) { window.__gptSwitchSkin = undefined; }
      return true;
    })()
    """

    static let statusExpression = """
    (() => {
      if (document.getElementById(\(jsLiteral(styleID)))?.isConnected !== true) return null;
      const theme = document.documentElement.dataset.gptswitchSkin;
      const revision = document.documentElement.dataset.gptswitchSkinRevision;
      return theme && revision ? `${theme}@${revision}` : (theme ?? null);
    })()
    """

    private static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
