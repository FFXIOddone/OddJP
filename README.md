# OddJP - Chat Translator for FFXI

A comprehensive chat translation addon for Ashita v4 that provides bidirectional translation between English and Japanese for Final Fantasy XI.

## Features

### Core Translation
- **Automatic Incoming Translation**: Translates Japanese chat messages to English in real-time
- **Outgoing Translation Commands**: Quick commands to translate and send English messages in Japanese
- **SJIS Encoding Support**: Properly handles FFXI's SJIS character encoding for Japanese text
- **Multiple Providers**: Support for Google Translate (free) and DeepL (with API key)

### Chat Integration
- **Smart Message Processing**: Automatically detects and translates Japanese text in chat
- **Channel Filtering**: Configure which chat channels to monitor (say/party/tell/linkshell/etc)
- **Message Reinjection**: Shows translated text inline with original messages
- **Auto-translate Detection**: Skips FFXI's built-in auto-translate phrases

### User Interface
- **Command Interface**: Comprehensive `/oddjp` commands for all settings
- **GUI Configuration**: ImGui-based settings panel (`/oddjp ui`)
- **Debug Tools**: Built-in debugging and testing commands
- **Persistent Settings**: Configuration saved between sessions

## Installation

1. Copy `oddjp.lua` to your Ashita `addons` folder
2. Load the addon: `/addon load oddjp`
3. Configure your preferred settings (see Configuration section)

## Quick Start

```
/oddjp on                    # Enable auto-translation
/oddjp provider google       # Use Google Translate (free)
/oddjp sendenc sjis         # Use SJIS encoding (recommended)
/oddjp incoming on          # Enable incoming translation
```

### Translation Commands

```
/jp <text>              # Translate and send to party
/jpsay <text>           # Translate and say
/jptell <player> <text> # Translate and send tell
```

## Configuration

### Basic Commands

| Command | Description |
|---------|-------------|
| `/oddjp on/off` | Toggle auto-translation |
| `/oddjp provider google\|deepl\|none` | Set translation provider |
| `/oddjp key <api_key>` | Set DeepL API key (required for DeepL) |
| `/oddjp sendenc sjis\|utf8` | Set output encoding |
| `/oddjp channel <s\|t\|l\|l2\|p\|a>` | Set default output channel |

### Advanced Options

| Command | Description |
|---------|-------------|
| `/oddjp dual on/off` | Send both English and Japanese |
| `/oddjp incoming on/off` | Toggle incoming translation |
| `/oddjp hiragana on/off` | Convert katakana to hiragana |
| `/oddjp debug on/off` | Toggle debug logging |
| `/oddjp ui` | Open configuration GUI |

### Channel Configuration

Configure which chat channels to monitor for incoming translation:
- **Say** (s) - Local chat
- **Party** (p) - Party chat  
- **Tell** (t) - Private messages
- **Linkshell** (l) - Linkshell chat
- **Linkshell2** (l2) - Second linkshell
- **Alliance** (a) - Alliance chat

## Translation Providers

### Google Translate (Free)
- No API key required
- Good quality for general translation
- Rate limits may apply for heavy usage

### DeepL (API Key Required)
- Higher quality translations
- Requires free DeepL API account
- Get your key at: https://www.deepl.com/api-free

## Troubleshooting

### Common Issues

**Translations not working?**
1. Check internet connectivity
2. Verify provider settings: `/oddjp status`
3. Enable debug logging: `/oddjp debug on`
4. Test HTTP connectivity: Check curl availability

**Japanese text not displaying correctly?**
1. Ensure SJIS encoding: `/oddjp sendenc sjis`
2. Check incoming translation: `/oddjp incoming on`
3. Test encoding detection: `/oddjp testenc おはよう`

**Commands not responding?**
1. Verify addon is loaded: `/addon list`
2. Check if blocked by other addons
3. Enable debug mode for detailed logging

### Debug Commands

| Command | Description |
|---------|-------------|
| `/oddjp status` | Show current configuration |
| `/oddjp test <text>` | Test EN→JA translation |
| `/oddjp testenc [text]` | Test encoding detection |
| `/oddjp inc` | Simulate incoming message |

### HTTP Requirements

The addon requires HTTP access for translation APIs:
- **Windows 10+**: curl included by default
- **Older Windows**: Install curl or use PowerShell fallback
- **Network**: Outbound HTTPS access to translation services

## Technical Details

### Encoding Handling
- **FFXI Chat**: SJIS (CP932) encoding
- **Translation APIs**: UTF-8 encoding
- **Auto-conversion**: SJIS ↔ UTF-8 as needed
- **Pattern Detection**: Smart encoding detection for mixed content

### Message Flow

**Incoming Messages:**
1. FFXI sends SJIS-encoded chat
2. Convert SJIS → UTF-8
3. Detect Japanese content
4. Translate JA → EN via API
5. Display: "original [translation]"

**Outgoing Messages:**
1. User types English command
2. Translate EN → JA via API
3. Convert UTF-8 → SJIS
4. Send to FFXI chat

### Performance
- **Rate Limiting**: Configurable delay between translations
- **Caching**: Phrasebook for common expressions
- **Fallbacks**: Graceful degradation when APIs unavailable
- **Memory**: Minimal memory footprint

## File Structure

```
oddjp.lua              # Main addon file
README.md              # This documentation
```

Use only the main `oddjp.lua` file - it contains all necessary functionality.

## Version Information

- **Version**: 1.5.3
- **Ashita**: v4 compatible
- **Last Updated**: August 2025
- **Status**: Production ready

## Support

For issues or feature requests:
1. Enable debug logging: `/oddjp debug on`
2. Reproduce the issue and check logs
3. Report with debug output and steps to reproduce

## License

This addon is provided as-is for the FFXI community. Please respect translation service terms of use and rate limits.
