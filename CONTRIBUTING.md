# Contributing

Thanks for helping! Bug reports, ideas and translation fixes are all welcome — please
[open an issue](../../issues) first for anything larger than a small fix.

## Translations

Strings live in `Resources/Localization/<language>.lproj/Localizable.strings`.
English is the reference: the keys are the English text, and `en.lproj` lists them all.

- To fix a translation, edit the value on the right of `=` in your language's file.
- To add a language, copy `en.lproj` to `<code>.lproj`, translate the values, and add
  the code to `CFBundleLocalizations` in `Resources/Info.plist` and to `AppLanguage`.
- Keep placeholders such as `%@` and `%lld`.
- Run `python3 tools/check_localizations.py` before sending a pull request.

Translations other than English and Chinese were drafted without native-speaker review,
so corrections are especially appreciated.

## Code

- Build with `./build.sh` (needs Xcode).
- Sideboard only reads from devices. Anything that changes a device (installing, sending,
  key presses) must happen only when the user asks, and must never change device settings.
- Check layouts in every language with `Sideboard --snapshot <folder>`.
