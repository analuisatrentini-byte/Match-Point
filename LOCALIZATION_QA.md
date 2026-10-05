# Localization QA

Match Point's non-pt-BR translations are draft strings produced from general fluency, not native market review. Do not treat a locale as release-ready until a native reviewer has approved the full UI in context.

## Release Gate

Before enabling a localized App Store market, complete all checks for that locale:

- Native reviewer signs off on UI copy, tone, tennis terminology, privacy wording, and responsible gambling wording.
- Reviewer checks key screens on device or simulator: onboarding, tabs, match detail, live tracker, profile, settings, privacy policy, data export, and account deletion.
- Reviewer confirms truncation and layout at default, large, and accessibility text sizes.
- Reviewer confirms legal references are appropriate for the target market, including GDPR/LGPD wording where shown.
- Any reviewer changes are applied to the matching `Match Point/Localizable.strings/<locale>` file.

## Locale Status

| Locale | Market | Status | Priority | Notes |
| --- | --- | --- | --- | --- |
| `pt-BR` | Brazil | Development language | Normal | Source language for string keys and baseline copy. |
| `en` | English-language markets | Native review required | Normal | Draft translation only. |
| `es` | Spanish-language markets | Native review required | Normal | Draft translation only. |
| `fr` | France/French-language markets | Native review required | Normal | Draft translation only. |
| `it` | Italy/Italian-language markets | Native review required | Normal | Draft translation only. |
| `de` | Germany/German-language markets | Native review required | High | Review legal tone and compound UI labels carefully. |
| `ja` | Japan | Native review required | High | Review tone, brevity, legal copy, and tennis terminology carefully. |

## Reviewer Handoff

Give reviewers the locale file, current screenshots, and this checklist. Ask them to return edited strings using the existing pt-BR keys exactly as-is; only values should change.
