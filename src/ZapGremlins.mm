// NppZapGremlins — remove/replace "gremlin" characters (BBEdit "Zap Gremlins" style).
//
// Search categories: Non-ASCII (>U+007F), Control (C0 except Tab/CR/LF, plus DEL),
// Null (U+0000). Actions: Delete / Replace with character / Replace with \uXXXX code
// (optionally transliterate to an ASCII equivalent first) / Replace with HTML entity
// (named when available, else numeric). Operates on the selection if any, else the
// whole document, as one undo step.
//
// Bonus: a "Highlight gremlins" toggle marks a curated set of invisible/ambiguous
// Unicode characters using a Scintilla indicator.
//
// Plugin-only: uses standard NPP/Scintilla plugin APIs; no host changes.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>
#include <map>
#include <cstdint>
#include <cstdio>

// ===========================================================================
// Plugin identity + menu
// ===========================================================================
static const char *PLUGIN_NAME = "Zap Gremlins";

enum MenuIdx { MI_Zap = 0, MI_QuickZap, MI_Settings, MI_Sep1, MI_Highlight, MI_Sep2, MI_About, NB_FUNC };
static FuncItem funcItem[NB_FUNC];
NppData nppData;

// ===========================================================================
// Scintilla helpers
// ===========================================================================
static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}
static NppHandle curSci() {
    int which = -1;
    npp(NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 1) ? nppData._scintillaSecondHandle : nppData._scintillaMainHandle;
}
static intptr_t sci(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(curSci(), msg, w, l);
}
static std::string sciGetAll() {
    intptr_t len = sci(SCI_GETLENGTH);
    if (len <= 0) return std::string();
    std::string buf((size_t)len, '\0');
    sci(SCI_GETTEXT, (uintptr_t)(len + 1), (intptr_t)buf.data());
    return buf;
}
static std::string sciGetRange(intptr_t a, intptr_t b) {
    if (b <= a) return std::string();
    std::string buf((size_t)(b - a) + 1, '\0');
    Sci_TextRangeFull tr; tr.chrg.cpMin = a; tr.chrg.cpMax = b; tr.lpstrText = buf.data();
    sci(SCI_GETTEXTRANGEFULL, 0, (intptr_t)&tr);
    buf.resize((size_t)(b - a));
    return buf;
}

// ===========================================================================
// UTF-8 codepoint decode / encode
// ===========================================================================
static uint32_t utf8Decode(const std::string &s, size_t i, int &len) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { len = 1; return c; }
    if ((c >> 5) == 0x6 && i + 1 < s.size()) { len = 2; return ((c & 0x1F) << 6) | (s[i+1] & 0x3F); }
    if ((c >> 4) == 0xE && i + 2 < s.size()) { len = 3; return ((c & 0x0F) << 12) | ((s[i+1] & 0x3F) << 6) | (s[i+2] & 0x3F); }
    if ((c >> 3) == 0x1E && i + 3 < s.size()) { len = 4; return ((c & 0x07) << 18) | ((s[i+1] & 0x3F) << 12) | ((s[i+2] & 0x3F) << 6) | (s[i+3] & 0x3F); }
    len = 1; return c; // invalid lead byte → treat as single (Latin-1-ish), counts as non-ASCII
}
// ===========================================================================
// Settings
// ===========================================================================
struct Settings {
    bool searchNonAscii = true;
    bool searchControl  = true;
    bool searchNull     = true;
    int  action         = 2;   // 0=Delete 1=ReplaceCode 2=ReplaceChar 3=ReplaceEntity
    std::string replaceChar = "*";
    bool useAsciiEquiv    = true;
    bool useNamedEntities = true;
    bool highlight        = false;
};
static Settings g_set;

static std::string nsToStd(NSString *s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }
static NSString *stdToNs(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

static std::string iniPath() {
    char buf[1024] = {0};
    npp(NPPM_GETPLUGINSCONFIGDIR, sizeof(buf), (intptr_t)buf);
    // Fallback only if the host returns empty (it does not on shipped versions):
    // the app-support base, NOT a legacy ~/.nextpad++ dot-folder.
    std::string dir = buf[0] ? buf : (nsToStd(NSHomeDirectory()) + "/Library/Application Support/Nextpad++/plugins/Config");
    return dir + "/NppZapGremlins.ini";
}
static void loadSettings() {
    @autoreleasepool {
        NSString *c = [NSString stringWithContentsOfFile:stdToNs(iniPath()) encoding:NSUTF8StringEncoding error:nil];
        if (!c) return;
        std::map<std::string, std::string> kv;
        for (NSString *raw in [c componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            std::string line = nsToStd(raw);
            auto p = line.find('=');
            if (p == std::string::npos || (!line.empty() && (line[0] == ';' || line[0] == '['))) continue;
            kv[line.substr(0, p)] = line.substr(p + 1);
        }
        auto B = [&](const char *k, bool &d){ auto it = kv.find(k); if (it != kv.end()) d = (it->second == "1" || it->second == "true"); };
        auto I = [&](const char *k, int &d){ auto it = kv.find(k); if (it != kv.end()) { try { d = std::stoi(it->second); } catch (...) {} } };
        B("searchNonAscii", g_set.searchNonAscii);
        B("searchControl", g_set.searchControl);
        B("searchNull", g_set.searchNull);
        I("action", g_set.action);
        if (kv.count("replaceChar")) g_set.replaceChar = kv["replaceChar"];
        B("useAsciiEquiv", g_set.useAsciiEquiv);
        B("useNamedEntities", g_set.useNamedEntities);
        B("highlight", g_set.highlight);
    }
}
static void saveSettings() {
    @autoreleasepool {
        std::string o = "; Zap Gremlins settings\n[General]\n";
        o += "searchNonAscii=" + std::string(g_set.searchNonAscii ? "1" : "0") + "\n";
        o += "searchControl=" + std::string(g_set.searchControl ? "1" : "0") + "\n";
        o += "searchNull=" + std::string(g_set.searchNull ? "1" : "0") + "\n";
        o += "action=" + std::to_string(g_set.action) + "\n";
        o += "replaceChar=" + g_set.replaceChar + "\n";
        o += "useAsciiEquiv=" + std::string(g_set.useAsciiEquiv ? "1" : "0") + "\n";
        o += "useNamedEntities=" + std::string(g_set.useNamedEntities ? "1" : "0") + "\n";
        o += "highlight=" + std::string(g_set.highlight ? "1" : "0") + "\n";
        [stdToNs(o) writeToFile:stdToNs(iniPath()) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// ===========================================================================
// Tables: ASCII transliteration, named HTML entities, curated gremlins
// ===========================================================================
static const std::map<uint32_t, std::string> &translitTable() {
    static const std::map<uint32_t, std::string> t = {
        {0x00A0, " "},   // nbsp
        {0x00AD, ""},    // soft hyphen
        {0x2002, " "}, {0x2003, " "}, {0x2004, " "}, {0x2005, " "}, {0x2006, " "},
        {0x2007, " "}, {0x2008, " "}, {0x2009, " "}, {0x200A, " "}, {0x202F, " "}, {0x205F, " "}, {0x3000, " "},
        {0x200B, ""}, {0x200C, ""}, {0x200D, ""}, {0xFEFF, ""}, // zero-width / BOM
        {0x2018, "'"}, {0x2019, "'"}, {0x201A, "'"}, {0x201B, "'"},
        {0x201C, "\""}, {0x201D, "\""}, {0x201E, "\""}, {0x201F, "\""},
        {0x2032, "'"}, {0x2033, "\""},
        {0x2010, "-"}, {0x2011, "-"}, {0x2012, "-"}, {0x2013, "-"}, {0x2014, "-"}, {0x2015, "-"}, {0x2212, "-"},
        {0x2026, "..."},
        {0x2022, "*"}, {0x00B7, "*"}, {0x2027, "*"},
        {0x00AB, "<<"}, {0x00BB, ">>"},
        {0x00D7, "x"}, {0x2044, "/"},
        {0x00A9, "(c)"}, {0x00AE, "(r)"}, {0x2122, "(tm)"},
        {0x00BC, "1/4"}, {0x00BD, "1/2"}, {0x00BE, "3/4"},
    };
    return t;
}
static const std::map<uint32_t, std::string> &namedEntityTable() {
    static const std::map<uint32_t, std::string> t = {
        {0x00A0, "nbsp"}, {0x00A9, "copy"}, {0x00AE, "reg"}, {0x2122, "trade"},
        {0x2013, "ndash"}, {0x2014, "mdash"}, {0x2018, "lsquo"}, {0x2019, "rsquo"},
        {0x201C, "ldquo"}, {0x201D, "rdquo"}, {0x2026, "hellip"}, {0x2022, "bull"},
        {0x00AB, "laquo"}, {0x00BB, "raquo"}, {0x00B7, "middot"}, {0x00AD, "shy"},
        {0x00D7, "times"}, {0x00BC, "frac14"}, {0x00BD, "frac12"}, {0x00BE, "frac34"},
        {0x00A1, "iexcl"}, {0x00BF, "iquest"}, {0x20AC, "euro"}, {0x00A3, "pound"},
        {0x00A5, "yen"}, {0x00A2, "cent"}, {0x00B0, "deg"}, {0x00B1, "plusmn"},
        {0x00E9, "eacute"}, {0x00E8, "egrave"}, {0x00E0, "agrave"}, {0x00FC, "uuml"},
        {0x00F6, "ouml"}, {0x00E4, "auml"}, {0x00F1, "ntilde"}, {0x00DF, "szlig"},
    };
    return t;
}
struct GremlinInfo { const char *desc; bool zeroWidth; };
static const std::map<uint32_t, GremlinInfo> &gremlinTable() {
    static const std::map<uint32_t, GremlinInfo> t = {
        {0x2013, {"en dash", false}}, {0x2018, {"left single quote", false}},
        {0x2019, {"right single quote", false}}, {0x2029, {"paragraph separator", true}},
        {0x2066, {"left-to-right isolate", true}}, {0x2069, {"pop directional isolate", true}},
        {0x0003, {"end of text", false}}, {0x000B, {"line tabulation", false}},
        {0x00A0, {"non-breaking space", false}}, {0x00AD, {"soft hyphen", false}},
        {0x200B, {"zero width space", true}}, {0x200C, {"zero width non-joiner", true}},
        {0x200E, {"left-to-right mark", true}}, {0x201C, {"left double quote", false}},
        {0x201D, {"right double quote", false}}, {0x202C, {"pop directional formatting", true}},
        {0x202D, {"left-to-right override", true}}, {0x202E, {"right-to-left override", true}},
        {0xFFFC, {"object replacement character", true}},
    };
    return t;
}

// ===========================================================================
// Classification + transform
// ===========================================================================
static bool isControlExclNull(uint32_t cp) {
    if (cp == 0) return false;                 // null handled separately
    if (cp == 0x09 || cp == 0x0A || cp == 0x0D) return false; // tab/lf/cr legitimate
    return cp < 0x20 || cp == 0x7F;            // C0 (minus the above) + DEL
}
static bool shouldZap(uint32_t cp) {
    if (g_set.searchNull && cp == 0) return true;
    if (g_set.searchControl && isControlExclNull(cp)) return true;
    if (g_set.searchNonAscii && cp > 0x7F) return true;
    return false;
}
static std::string replacementFor(uint32_t cp) {
    switch (g_set.action) {
        case 0: return ""; // delete
        case 1: { // replace with \uXXXX, optionally ASCII-equivalent first
            if (g_set.useAsciiEquiv) { auto it = translitTable().find(cp); if (it != translitTable().end()) return it->second; }
            char b[16];
            if (cp <= 0xFFFF) snprintf(b, sizeof b, "\\u%04X", cp);
            else snprintf(b, sizeof b, "\\u{%X}", cp);
            return b;
        }
        case 3: { // HTML entity (named if available, else numeric)
            if (g_set.useNamedEntities) { auto it = namedEntityTable().find(cp); if (it != namedEntityTable().end()) return "&" + it->second + ";"; }
            return "&#" + std::to_string(cp) + ";";
        }
        case 2: default: { // replace with character
            std::string r = g_set.replaceChar;
            return r.empty() ? "*" : r;
        }
    }
}

// ===========================================================================
// Zap engine
// ===========================================================================
static void showResult(int count) {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Zap Gremlins";
        a.informativeText = count > 0
            ? [NSString stringWithFormat:@"Zapped %d gremlin character%s.", count, count == 1 ? "" : "s"]
            : @"No gremlin characters found.";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}
static void refreshHighlight();

// Core zap using the current saved settings. Returns the number of characters
// zapped (0 if no categories enabled or nothing matched). No UI of its own.
static int doZap() {
    if (!(g_set.searchNonAscii || g_set.searchControl || g_set.searchNull)) return 0;

    intptr_t selStart = sci(SCI_GETSELECTIONSTART);
    intptr_t selEnd   = sci(SCI_GETSELECTIONEND);
    bool useSel = (selEnd > selStart);
    std::string src = useSel ? sciGetRange(selStart, selEnd) : sciGetAll();
    if (src.empty()) return 0;

    std::string out;
    out.reserve(src.size());
    int count = 0;
    for (size_t i = 0; i < src.size();) {
        int len = 1;
        uint32_t cp = utf8Decode(src, i, len);
        if (shouldZap(cp)) { out += replacementFor(cp); count++; }
        else out.append(src, i, len);
        i += len;
    }

    if (count == 0) return 0;

    sci(SCI_BEGINUNDOACTION);
    if (useSel) {
        sci(SCI_SETTARGETRANGE, (uintptr_t)selStart, selEnd);
        sci(SCI_REPLACETARGET, (uintptr_t)out.size(), (intptr_t)out.c_str());
        sci(SCI_SETSEL, (uintptr_t)selStart, (intptr_t)(selStart + (intptr_t)out.size()));
    } else {
        sci(SCI_SETTEXT, 0, (intptr_t)out.c_str());
    }
    sci(SCI_ENDUNDOACTION);

    if (g_set.highlight) refreshHighlight();
    return count;
}

// Interactive zap (from the dialog) — reports the result.
static void runZap() { showResult(doZap()); }

// Quick Zap — runs with the saved settings, no dialogs or result popups, so it
// can be bound to a shortcut or driven from a macro.
static void quickZap() { doZap(); }

// ===========================================================================
// Highlighter (Scintilla indicator over curated gremlin list)
// ===========================================================================
static int g_indicator = -1;
static void ensureIndicator() {
    if (g_indicator >= 0) return;
    int id = -1;
    npp(NPPM_ALLOCATEINDICATOR, 1, (intptr_t)&id);
    g_indicator = (id >= 0) ? id : 28;
    NppHandle h = curSci();
    nppData._sendMessage(h, SCI_INDICSETSTYLE, (uintptr_t)g_indicator, INDIC_ROUNDBOX);
    nppData._sendMessage(h, SCI_INDICSETFORE, (uintptr_t)g_indicator, 0x4444E0); // BGR red
    nppData._sendMessage(h, SCI_INDICSETALPHA, (uintptr_t)g_indicator, 80);
    nppData._sendMessage(h, SCI_INDICSETUNDER, (uintptr_t)g_indicator, 1);
}
static void clearHighlight() {
    if (g_indicator < 0) return;
    NppHandle h = curSci();
    intptr_t len = nppData._sendMessage(h, SCI_GETLENGTH, 0, 0);
    nppData._sendMessage(h, SCI_SETINDICATORCURRENT, (uintptr_t)g_indicator, 0);
    nppData._sendMessage(h, SCI_INDICATORCLEARRANGE, 0, len);
}
static void refreshHighlight() {
    ensureIndicator();
    clearHighlight();
    if (!g_set.highlight) return;
    std::string src = sciGetAll();
    NppHandle h = curSci();
    nppData._sendMessage(h, SCI_SETINDICATORCURRENT, (uintptr_t)g_indicator, 0);
    for (size_t i = 0; i < src.size();) {
        int len = 1;
        uint32_t cp = utf8Decode(src, i, len);
        if (gremlinTable().count(cp))
            nppData._sendMessage(h, SCI_INDICATORFILLRANGE, (uintptr_t)i, len);
        i += len;
    }
}

// ===========================================================================
// Dialog (BBEdit "Zap Gremlins" layout)
// ===========================================================================
@interface ZGDialog : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSButton *cbNonAscii, *cbControl, *cbNull;
@property(nonatomic, strong) NSButton *rDelete, *rCode, *rChar, *rEntity;
@property(nonatomic, strong) NSTextField *charField;
@property(nonatomic, strong) NSButton *cbAsciiEquiv, *cbNamedEntities;
@property(nonatomic, assign) NSModalResponse result;
@property(nonatomic, assign) BOOL settingsOnly;   // YES = Settings screen (Save), NO = Zap now
@end

@implementation ZGDialog
- (instancetype)initSettingsOnly:(BOOL)s { if ((self = [super init])) { _settingsOnly = s; [self build]; } return self; }

- (NSButton *)check:(NSString *)t at:(NSRect)f {
    NSButton *b = [NSButton checkboxWithTitle:t target:nil action:nil];
    b.frame = f; [self.window.contentView addSubview:b]; return b;
}
- (NSButton *)radio:(NSString *)t at:(NSRect)f tag:(NSInteger)tag {
    NSButton *b = [NSButton radioButtonWithTitle:t target:self action:@selector(radioChanged:)];
    b.frame = f; b.tag = tag; [self.window.contentView addSubview:b]; return b;
}
- (NSTextField *)label:(NSString *)t at:(NSRect)f bold:(BOOL)bold {
    NSTextField *l = [NSTextField labelWithString:t];
    l.frame = f; if (bold) l.font = [NSFont boldSystemFontOfSize:13];
    [self.window.contentView addSubview:l]; return l;
}

- (void)build {
    NSRect r = NSMakeRect(0, 0, 470, 340);
    _window = [[NSWindow alloc] initWithContentRect:r
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered defer:YES];
    _window.title = _settingsOnly ? @"Zap Gremlins — Settings" : @"Zap Gremlins";
    _window.releasedWhenClosed = NO;   // we reuse the window; orderOut, don't dealloc
    _window.delegate = self;            // so the close (X) button can end the modal session

    [self label:@"Search for:" at:NSMakeRect(20, 300, 200, 18) bold:YES];
    _cbNonAscii = [self check:@"Non-ASCII characters"          at:NSMakeRect(36, 274, 280, 20)];
    _cbControl  = [self check:@"Control characters"            at:NSMakeRect(36, 250, 280, 20)];
    _cbNull     = [self check:@"Null (ASCII 0) characters"     at:NSMakeRect(36, 226, 280, 20)];

    [self label:@"and then:" at:NSMakeRect(20, 192, 200, 18) bold:YES];
    // left column
    _rDelete = [self radio:@"Delete"             at:NSMakeRect(36, 164, 200, 20) tag:0];
    _rCode   = [self radio:@"Replace with code"  at:NSMakeRect(36, 134, 200, 20) tag:1];
    _cbAsciiEquiv = [self check:@"Use ASCII equivalent" at:NSMakeRect(56, 110, 200, 20)];
    // right column
    _rChar   = [self radio:@"Replace with character:" at:NSMakeRect(248, 164, 170, 20) tag:2];
    _charField = [[NSTextField alloc] initWithFrame:NSMakeRect(420, 162, 30, 24)];
    _charField.alignment = NSTextAlignmentCenter;
    [_window.contentView addSubview:_charField];
    _rEntity = [self radio:@"Replace with HTML entity" at:NSMakeRect(248, 134, 200, 20) tag:3];
    _cbNamedEntities = [self check:@"Use named entities" at:NSMakeRect(268, 110, 190, 20)];

    NSButton *primary = [NSButton buttonWithTitle:(_settingsOnly ? @"Save" : @"Zap")
                                           target:self
                                           action:(_settingsOnly ? @selector(save:) : @selector(zap:))];
    primary.frame = NSMakeRect(370, 20, 90, 32); primary.keyEquivalent = @"\r";
    [_window.contentView addSubview:primary];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(270, 20, 90, 32); cancel.keyEquivalent = @"\e";
    [_window.contentView addSubview:cancel];

    [self loadFromSettings];
}

- (void)loadFromSettings {
    _cbNonAscii.state = g_set.searchNonAscii ? NSControlStateValueOn : NSControlStateValueOff;
    _cbControl.state  = g_set.searchControl  ? NSControlStateValueOn : NSControlStateValueOff;
    _cbNull.state     = g_set.searchNull     ? NSControlStateValueOn : NSControlStateValueOff;
    _charField.stringValue = stdToNs(g_set.replaceChar);
    _cbAsciiEquiv.state    = g_set.useAsciiEquiv    ? NSControlStateValueOn : NSControlStateValueOff;
    _cbNamedEntities.state = g_set.useNamedEntities ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *radios[4] = { _rDelete, _rCode, _rChar, _rEntity };
    for (int i = 0; i < 4; ++i) radios[i].state = (g_set.action == i) ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateEnable];
}
- (void)radioChanged:(NSButton *)sender {
    NSButton *radios[4] = { _rDelete, _rCode, _rChar, _rEntity };
    for (int i = 0; i < 4; ++i) radios[i].state = (radios[i] == sender) ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateEnable];
}
- (void)updateEnable {
    int act = [self selectedAction];
    _charField.enabled    = (act == 2);
    _cbAsciiEquiv.enabled = (act == 1);
    _cbNamedEntities.enabled = (act == 3);
}
- (int)selectedAction {
    NSButton *radios[4] = { _rDelete, _rCode, _rChar, _rEntity };
    for (int i = 0; i < 4; ++i) if (radios[i].state == NSControlStateValueOn) return i;
    return 2;
}
- (void)applyAndSave {
    g_set.searchNonAscii = (_cbNonAscii.state == NSControlStateValueOn);
    g_set.searchControl  = (_cbControl.state  == NSControlStateValueOn);
    g_set.searchNull     = (_cbNull.state     == NSControlStateValueOn);
    g_set.action = [self selectedAction];
    std::string rc = nsToStd(_charField.stringValue);
    g_set.replaceChar = rc.empty() ? "*" : rc;
    g_set.useAsciiEquiv    = (_cbAsciiEquiv.state    == NSControlStateValueOn);
    g_set.useNamedEntities = (_cbNamedEntities.state == NSControlStateValueOn);
    saveSettings();
}
// Zap screen: persist settings and signal OK (the caller then runs the zap).
- (void)zap:(id)sender { [self applyAndSave]; self.result = NSModalResponseOK; [NSApp stopModal]; }
// Settings screen: persist settings only — no zapping.
- (void)save:(id)sender { [self applyAndSave]; self.result = NSModalResponseOK; [NSApp stopModal]; }
- (void)cancel:(id)sender { self.result = NSModalResponseCancel; [NSApp stopModal]; }
// Closing via the window's red X button must also end the modal session,
// otherwise the app stays in a modal loop with no window and only beeps.
- (void)windowWillClose:(NSNotification *)note {
    self.result = NSModalResponseCancel;
    [NSApp stopModal];
}
- (NSModalResponse)runModal {
    self.result = NSModalResponseCancel;
    [self.window center];
    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];
    return self.result;
}
@end

// ===========================================================================
// Menu actions
// ===========================================================================
static void cmdZap() {
    @autoreleasepool {
        static ZGDialog *dlg = nil;
        dlg = [[ZGDialog alloc] initSettingsOnly:NO];
        if ([dlg runModal] == NSModalResponseOK) runZap();
    }
}
// Dedicated Settings screen — same controls as the Zap window, but its button
// is "Save" and it never zaps. This is where Quick Zap's behavior is configured.
static void cmdSettings() {
    @autoreleasepool {
        static ZGDialog *dlg = nil;
        dlg = [[ZGDialog alloc] initSettingsOnly:YES];
        [dlg runModal];
    }
}
static void cmdToggleHighlight() {
    g_set.highlight = !g_set.highlight;
    npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[MI_Highlight]._cmdID, g_set.highlight ? 1 : 0);
    saveSettings();
    refreshHighlight();
}
static void cmdAbout() {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Zap Gremlins";
        a.informativeText =
            @"Version 1.0 (macOS)\n\n"
            "Remove or replace non-ASCII, control, and null \"gremlin\" characters "
            "(BBEdit-style). Operates on the selection if any, else the whole document.\n\n"
            "Optional gremlin highlighting marks a curated set of invisible and "
            "ambiguous Unicode characters.";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

// ===========================================================================
// Toolbar
// ===========================================================================
static void handleToolbarModification() {
    npp(NPPM_ADDTOOLBARICON_FORDARKMODE, (uintptr_t)funcItem[MI_Zap]._cmdID, (intptr_t)"zapgremlins.png");
}

// ===========================================================================
// Plugin exports
// ===========================================================================
static void setItem(int idx, const char *name, PFUNCPLUGINCMD fn, bool check = false) {
    strncpy(funcItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE - 1);
    funcItem[idx]._pFunc = fn;
    funcItem[idx]._init2Check = check;
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    memset(funcItem, 0, sizeof(funcItem));
    loadSettings();
    setItem(MI_Zap, "Zap Gremlins…", cmdZap);
    setItem(MI_QuickZap, "Quick Zap", quickZap);  // silent, uses saved settings — shortcut/macro friendly
    setItem(MI_Settings, "Settings…", cmdSettings);
    setItem(MI_Sep1, "", nullptr);
    setItem(MI_Highlight, "Highlight gremlins", cmdToggleHighlight, g_set.highlight);
    setItem(MI_Sep2, "", nullptr);
    setItem(MI_About, "About", cmdAbout);
}
extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }
extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = NB_FUNC; return funcItem; }
extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION: handleToolbarModification(); break;
        case NPPN_READY: if (g_set.highlight) refreshHighlight(); break;
        case NPPN_BUFFERACTIVATED: if (g_set.highlight) refreshHighlight(); break;
        case NPPN_SHUTDOWN: saveSettings(); break;
        default: break;
    }
}
extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) { return 1; }
