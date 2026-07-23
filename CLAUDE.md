# Freewrite - Technical Documentation for AI Agents

> **⚠️ IMPORTANT FOR AI AGENTS**: This file (`AGENTS.md`) and `CLAUDE.md` are clones and must be kept in sync.
>
> Update both files when changes are **substantial** and meaningfully affect future agent understanding (for example: architecture, data flow, storage/permissions, threading behavior, user-facing workflows, or major bug fixes).
>
> For minor tweaks (small UI polish, copy edits, tiny refactors), updates are optional. Do **not** churn these docs on every small code change.
>
> If one file is updated, mirror the same change in the other file immediately.

## Product Vision & User Experience

### What is Freewrite?

Freewrite is a **distraction-free writing environment** for macOS designed around the concept of stream-of-consciousness writing and video journaling. The core philosophy is to remove barriers between thought and writing by creating a minimalist, opinionated interface that prioritizes the act of writing over formatting, organization, or editing.

### User Experience Philosophy

**Core Principles:**
1. **No Backspace (Optional)**: Users can disable the backspace key to encourage forward-thinking writing without self-editing
2. **Timed Sessions**: Built-in timer (default 15 minutes) creates focused writing sprints
3. **Auto-Everything**: Auto-save, auto-new-entry, auto-timestamp - the app manages logistics so users can focus on writing
4. **Local-First**: All data stays on the user's machine in plain markdown files they can access directly
5. **Minimal UI**: Most UI elements hide during timed sessions, leaving only the text

### Use Cases

**Primary Use Case - Stream of Consciousness Writing:**
- Users open the app and start writing immediately (no "New Document" dialog)
- The app creates a new entry automatically at the start of each day
- Writing is saved continuously with no manual save action
- Timer creates urgency and prevents over-editing
- Backspace disable forces forward momentum in thinking

**Secondary Use Case - Video Journaling:**
- Quick video capture for visual thoughts/ideas
- Video entries stored alongside text entries in chronological history
- One-click recording with built-in timer
- Local storage ensures privacy for personal video journals

**Tertiary Use Case - AI-Assisted Reflection:**
- "Chat" opens a native right-side AI panel grounded in the note being viewed
- Text chat streams responses and agent tool activity; "Call" starts the same
  configurable voice experience available from the bottom-nav Voice button
- Text chats and completed voice calls share a local conversation history
- The agent can search the current note, search the live web, find public web
  images, and read a specific public URL when those tools are relevant

**Hidden Power Feature - Long-Form Writing:**
- Despite minimalist interface, supports full markdown
- Entries can be exported as PDFs
- Font and size customization for comfort during long sessions
- Dark mode for night writing

## Overview

Freewrite is a native macOS writing application built with SwiftUI that allows users to write text entries and record video entries. All data is stored locally in `~/Documents/Freewrite/`.

## Architecture

### Technology Stack
- **Framework**: SwiftUI (macOS)
- **Minimum macOS Version**: 14.0
- **Language**: Swift 5.0
- **Build System**: Xcode
- **Media**: AVFoundation for camera/video recording

### Project Structure

```
freewrite/
├── freewrite.xcodeproj/          # Xcode project file
├── freewrite/
│   ├── freewriteApp.swift        # App entry point
│   ├── ContentView.swift         # Main view (1400+ lines)
│   ├── VideoRecordingView.swift  # Video recording interface
│   ├── VideoPlayerView.swift     # Video playback interface
│   └── freewrite.entitlements    # App permissions
├── CLAUDE.md                     # This file
└── AGENTS.md                     # Duplicate of this file
```

## Data Model

### Entry Types

```swift
enum EntryType {
    case text
    case video
}

struct HumanEntry: Identifiable {
    let id: UUID
    let date: String              // Display format: "MMM d" (e.g., "Feb 20")
    let filename: String          // Format: [UUID]-[YYYY-MM-DD-HH-mm-ss].md
    var previewText: String       // First 30 chars or "Video Entry"
    var entryType: EntryType      // .text or .video
    var videoFilename: String?    // Format: [UUID]-[YYYY-MM-DD-HH-mm-ss].mov
}
```

### File Storage

**Location**: `~/Documents/Freewrite/`

**Text Entries**:
- Format: Markdown (.md)
- Naming: `[UUID]-[YYYY-MM-DD-HH-mm-ss].md`
- Content: Plain UTF-8 text
- Example: `[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04].md`

**Video Entries**:
- Format: QuickTime Movie (.mov)
- Naming: `[UUID]-[YYYY-MM-DD-HH-mm-ss].mov`
- Metadata: Corresponding `.md` file with "Video Entry" text in `~/Documents/Freewrite/`
- Storage layout: `~/Documents/Freewrite/Videos/[UUID]-[YYYY-MM-DD-HH-mm-ss]/`
- Directory contents:
  - `[UUID]-[YYYY-MM-DD-HH-mm-ss].mov`
  - `thumbnail.jpg`
  - `transcript.md` (optional; speech transcript for that recording)
- Example directory: `~/Documents/Freewrite/Videos/[6910BBDE-75FC-415C-ABB9-C76644B037B2]-[2026-02-20-08-01-04]/`

**AI Conversations**:
- Text chat: `~/Documents/Freewrite/Conversations/[conversation-uuid].json`
- Voice calls: `~/Documents/Freewrite/VoiceSessions/[entry-ref]/[session-id]/`
- Text JSON includes messages, citations, image artifacts, tool activity, model,
  token usage, latency, and estimated cost. Voice directories include transcript,
  metadata, telemetry, and saved background-strategy briefs.
- When a custom Freewrite folder is selected, new text and voice conversations
  are written under that root. The history loader also reads the legacy default
  VoiceSessions location so earlier calls remain visible.

## Key Components

### ContentView.swift

The main view containing all UI and business logic.

#### State Variables (Selection)

```swift
@State private var entries: [HumanEntry] = []           // All loaded entries
@State private var text: String = ""                    // Current text editor content
@State private var selectedEntryId: UUID? = nil         // Currently selected entry
@State private var showingVideoRecording = false        // Video recording overlay visibility
@State private var currentVideoURL: URL? = nil          // Video playback URL
@State private var showingSidebar = false               // History sidebar visibility
@State private var colorScheme: ColorScheme = .light    // Light/dark theme
@State private var fontSize: CGFloat = 18               // Text size (16-26px)
@State private var selectedFont: String = "Lato-Regular"// Current font
@State private var timerIsRunning = false               // Timer state
@State private var timeRemaining: Int = 900             // Timer (seconds)
@State private var backspaceDisabled = false            // Backspace lock
```

#### Core Functions

**Entry Management**:
- `loadExistingEntries()` - Loads all .md and .mov files from documents directory
- `createNewEntry()` - Creates new text entry
- `saveEntry(entry:)` - Saves text to .md file
- `loadEntry(entry:)` - Loads text or video for display
- `deleteEntry(entry:)` - Deletes entry and associated files
- `saveVideoEntry(from:)` - Saves recorded video and creates metadata

**Important**: When modifying the `entries` array from async contexts, wrap in `DispatchQueue.main.async` to prevent collection mutation crashes.

### VideoRecordingView.swift

Handles camera access and video recording.

#### CameraManager Class

```swift
class CameraManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingTime: Int = 0
    @Published var permissionGranted = false

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureMovieFileOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
}
```

**Key Methods**:
- `setupCamera()` - Configures AVCaptureSession with video/audio inputs
- `startRecording(to:)` - Begins recording to temporary file
- `stopRecording()` - Stops recording and triggers completion handler
- `cleanup()` - Releases camera resources

**Critical**: Always use `beginConfiguration()` and `commitConfiguration()` when modifying AVCaptureSession to prevent crashes.
**UI Pattern**: The recorder is rendered as an immersive edge-to-edge overlay with a transparent bottom nav and a floating circular record control.

### VideoPlayerView.swift

Simple AVKit-based video player for playback.

```swift
struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?
}
```

## UI Layout

### Main Interface

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│                    Text Editor Area                     │
│              (or Video Player if video)                 │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  Bottom Nav Bar:                                        │
│  [16px] • [Lato] • [Arial] • [System] • [Serif] • ...  │
│  ... [15:00] • [🎥] • [Chat] • [Backspace] • [...]     │
└─────────────────────────────────────────────────────────┘
```

### Sidebar (History)

```
┌──────────────┐
│   History    │
├──────────────┤
│ 📹 Video...  │ ← Video entry with thumbnail
│ Feb 20       │
├──────────────┤
│ This is a... │ ← Text entry with preview
│ Feb 19       │
├──────────────┤
│ Another ...  │
│ Feb 18       │
└──────────────┘
```

## Navigation Bar Items

### Left Side (Font Controls)
- **Font Size**: Cycles through [16, 18, 20, 22, 24, 26]px
- **Font Selection**: Lato, Arial, System, Serif, Random
- Hover changes cursor to pointing hand
- **Video Mode Left Slot**: Replaced by `Copy Transcript` when viewing a video entry

### Right Side (Utilities)
- **Timer**: Shows time remaining, click to start/stop, double-click to reset
- **Video Camera (🎥)**: Opens immersive video recording overlay
- **Chat**: Toggles the native note-aware AI side panel
- **Backspace Toggle**: Enable/disable backspace key
- **Fullscreen**: Toggle fullscreen mode
- **New Entry**: Creates new text entry
- **Theme Toggle**: 🌙/☀️ for dark/light mode
- **History**: 🕐 Shows/hides sidebar

## Video Recording Flow

1. User clicks video camera icon (🎥)
2. Camera icon switches to a small spinner while preflight runs
3. App requests/validates **all required permissions**: camera + microphone + speech recognition
4. If any permission is missing, recorder is **not** presented; a compact popover above the camera icon explains what is missing and links to System Settings
5. Once camera session is fully ready (plus a short presentation delay), `VideoRecordingView` is rendered via `.overlay` on top of `ContentView` with animations disabled for open/close (plain swap, no transition)
6. Camera preview fills the entire window content area edge-to-edge
7. Transparent bottom nav appears over video with: `Close`, recording status, recording control text (`Start Recording` / `Stop Recording`), and timer
8. User clicks "Start Recording"
   - Recording begins to temp file
   - Timer starts counting up
   - Button changes to "Stop Recording"
9. User clicks "Stop Recording"
   - Recording stops
   - Speech transcript is finalized (spacing + sentence endings/capitalization)
   - `onRecordingComplete` closure called with temp URL + finalized transcript
10. `saveVideoEntry(from:transcript:)` called
   - Creates per-entry video directory in `~/Documents/Freewrite/Videos/[UUID]-[date]/`
   - Video copied from temp to `~/Documents/Freewrite/Videos/[UUID]-[date]/[UUID]-[date].mov`
   - Thumbnail generated once and saved to `~/Documents/Freewrite/Videos/[UUID]-[date]/thumbnail.jpg`
   - Transcript saved to `~/Documents/Freewrite/Videos/[UUID]-[date]/transcript.md` when available
   - Metadata file created: `[UUID]-[date].md` with "Video Entry"
   - Entry added to `entries` array (on main thread), selected immediately, and loaded into the main view
   - Playback starts automatically with audio enabled
   - Overlay dismissed
11. If user clicks `Close` while recording, the temp recording is discarded and no entry is created; recorder dismisses first, then camera cleanup runs on disappear

## Video Playback Flow

1. User clicks video entry in sidebar
2. `loadEntry(entry:)` checks `entry.entryType`
3. If `.video`:
   - Sets `currentVideoURL` to video file path
   - Clears `text`
4. Main view checks `if let videoURL = currentVideoURL`
5. Shows `VideoPlayerView(videoURL:)` instead of TextEditor
6. Video auto-plays muted with standard AVKit controls

## Entry Loading Logic

On app launch (`onAppear`):

1. `loadExistingEntries()` called
2. Reads all files from `~/Documents/Freewrite/`
3. Filters for canonical `.md` entries and derives expected `.mov` name from each `.md`
4. For each `.md` file:
   - Extracts UUID and date from filename via regex
   - Checks for corresponding `.mov` in this order:
     - `~/Documents/Freewrite/Videos/[entry-base]/[entry].mov` (current layout)
     - `~/Documents/Freewrite/Videos/[entry].mov` (legacy flat layout)
     - `~/Documents/Freewrite/[entry].mov` (oldest legacy layout)
   - Creates `HumanEntry` with appropriate type
5. Sorts entries by date (newest first)
6. Applies launch selection rules in order:
   - If newest entry is a video entry: create a new text entry and select it (never open directly into video on app launch)
   - Else if no entries: create welcome entry
   - Else if no empty entry exists for today (and app is not in the single-welcome-entry state): create a new empty entry
   - Else select the most recent empty entry from today (or the welcome entry if it's the only entry)

## Auto-Save Behavior

Text is auto-saved on every change:

```swift
.onChange(of: text) { _ in
    if let currentId = selectedEntryId,
       let currentEntry = entries.first(where: { $0.id == currentId }) {
        saveEntry(entry: currentEntry)
    }
}
```

## Permissions

Required entitlements in `freewrite.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.personal-information.speech-recognition</key>
<true/>
```

Privacy usage descriptions (in Xcode project build settings):

```
INFOPLIST_KEY_NSCameraUsageDescription = "Freewrite needs camera access to record video entries."
INFOPLIST_KEY_NSMicrophoneUsageDescription = "Freewrite needs microphone access to record audio with your video entries."
INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "Freewrite uses speech recognition to transcribe your video entries."
```

## Technical Nuances & Implementation Details

### Threading Model

The app uses a **hybrid threading approach**:

1. **Main Thread**: All UI updates and `@State` mutations
2. **Global Queue**: File I/O operations (reading/writing markdown files)
3. **AVFoundation Queue**: Camera setup and video capture

**Critical Threading Issue**:
SwiftUI's `ForEach` creates an enumerator over the `entries` array. If you modify this array (insert, remove, replace) while the enumerator is active, you get `NSGenericException: Collection was mutated while being enumerated`.

**Solution Pattern**:
```swift
// When in async context (camera completion handler, DispatchQueue callback):
DispatchQueue.main.async {
    self.entries.insert(newEntry, at: 0)  // Safe
}

// When in loadExistingEntries:
let loadedEntries = mdFiles.compactMap { ... }  // Work on local copy
entries = loadedEntries  // Assign once to @State
// Now safe to check entries.contains, entries.first, etc.
```

### File System Architecture

**Why UUID + Timestamp Naming?**

The filename format `[UUID]-[YYYY-MM-DD-HH-mm-ss].md` serves multiple purposes:

1. **UUID**: Ensures global uniqueness even if multiple devices sync to same folder
2. **Timestamp**: Human-readable sorting in Finder without opening files
3. **Brackets**: Makes regex extraction reliable: `\\[(.*?)\\]` and `\\[(\\d{4}-\\d{2}-\\d{2}-\\d{2}-\\d{2}-\\d{2})\\]`

**File Loading Algorithm**:

```swift
// 1. Get all files
let fileURLs = try fileManager.contentsOfDirectory(at: documentsDirectory, ...)
let mdFiles = fileURLs.filter { $0.pathExtension == "md" }

// 2. Parse each .md file
let entriesWithDates = mdFiles.compactMap { fileURL -> (entry, date, content)? in
    // Extract UUID from filename using regex
    let uuidMatch = filename.range(of: "\\[(.*?)\\]", options: .regularExpression)
    let uuid = UUID(uuidString: String(filename[uuidMatch].dropFirst().dropLast()))

    // Extract timestamp
    let dateMatch = filename.range(of: "\\[(\\d{4}-\\d{2}-\\d{2}-\\d{2}-\\d{2}-\\d{2})\\]", ...)
    let dateString = String(filename[dateMatch].dropFirst().dropLast())

    // Parse date for sorting
    dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    let fileDate = dateFormatter.date(from: dateString)

    // Check for corresponding video
    let videoFilename = filename.replacingOccurrences(of: ".md", with: ".mov")
    let hasVideo = hasVideoAsset(for: videoFilename) // checks current + legacy locations

    // Read content for preview
    let content = try String(contentsOf: fileURL, encoding: .utf8)
    let preview = content.replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
    let truncated = preview.isEmpty ? "" : String(preview.prefix(30)) + "..."

    return (entry: HumanEntry(...), date: fileDate, content: content)
}

// 3. Sort by actual date (not display date)
entries = entriesWithDates
    .sorted { $0.date > $1.date }  // Newest first
    .map { $0.entry }
```

**Why separate .md and .mov files instead of embedding?**

- User can open .md files in any text editor
- Video files can be played in QuickTime independently
- Easier to backup/sync text separately from large video files
- Transparent file format for user ownership
- Per-entry video directories keep each recording's media + thumbnail together

### Auto-Save State Machine

The app implements **continuous auto-save** with debouncing:

```swift
.onChange(of: text) { _ in
    if let currentId = selectedEntryId,
       let currentEntry = entries.first(where: { $0.id == currentId }) {
        saveEntry(entry: currentEntry)
    }
}
```

**State Transitions**:
1. User types character → `text` state updates
2. `.onChange` fires immediately
3. `saveEntry()` writes to disk synchronously (fast on SSD)
4. No loading spinner needed (happens in <10ms)

**Edge Case**: What if user switches entries before save completes?

```swift
Button(action: {
    if selectedEntryId != entry.id {
        // Save current entry BEFORE switching
        if let currentId = selectedEntryId,
           let currentEntry = entries.first(where: { $0.id == currentId }) {
            saveEntry(entry: currentEntry)
        }

        selectedEntryId = entry.id
        loadEntry(entry: entry)
    }
})
```

This ensures no data loss on rapid entry switching.

### Timer Implementation Details

The timer is **not a countdown** - it's a visual focus tool:

```swift
@State private var timeRemaining: Int = 900  // 15 minutes default
@State private var timerIsRunning = false

let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

.onReceive(timer) { _ in
    if timerIsRunning && timeRemaining > 0 {
        timeRemaining -= 1
    } else if timeRemaining == 0 {
        timerIsRunning = false
        // Show bottom nav again when timer expires
        bottomNavOpacity = 1.0
    }
}
```

**UI Behavior During Timer**:
- When timer starts: Bottom nav fades out after 1 second
- While running: Nav only appears on hover
- When timer ends: Nav fades back in

This creates **immersion** - the UI disappears, leaving only text and timer.

**Timer Adjustment**:
- Scroll wheel over timer: Adjust in 5-minute increments
- Click: Start/pause
- Double-click: Reset to 15 minutes

```swift
NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
    if isHoveringTimer {
        let scrollBuffer = event.deltaY * 0.25
        if abs(scrollBuffer) >= 0.1 {
            let currentMinutes = timeRemaining / 60
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, ...)
            let direction = -scrollBuffer > 0 ? 5 : -5
            let newMinutes = currentMinutes + direction
            let roundedMinutes = (newMinutes / 5) * 5
            timeRemaining = roundedMinutes * 60
        }
    }
    return event
}
```

### Backspace Disable Mechanism

**Implementation**:
```swift
@State private var backspaceDisabled = false

NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if backspaceDisabled && (event.keyCode == 51 || event.keyCode == 117) {
        return nil  // Swallow the event
    }
    return event
}
```

**macOS Key Codes**:
- 51: Delete/Backspace key
- 117: Forward delete (fn+delete)

**Why this matters**: Forces users to write without editing, embracing imperfection and maintaining flow state.

### Video Recording Architecture

**AVFoundation Setup Sequence**:

```swift
// 1. Create session
captureSession = AVCaptureSession()

// 2. Get devices
let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
let audioDevice = AVCaptureDevice.default(for: .audio)

// 3. Create inputs
let videoInput = try AVCaptureDeviceInput(device: videoDevice)
let audioInput = try AVCaptureDeviceInput(device: audioDevice)

// 4. CRITICAL: Begin configuration
captureSession?.beginConfiguration()

// 5. Configure session
captureSession?.sessionPreset = .high
captureSession?.addInput(videoInput)
captureSession?.addInput(audioInput)

// 6. Add output
videoOutput = AVCaptureMovieFileOutput()
captureSession?.addOutput(videoOutput!)
audioDataOutput = AVCaptureAudioDataOutput()
audioDataOutput?.setSampleBufferDelegate(self, queue: speechQueue)
captureSession?.addOutput(audioDataOutput!)

// 7. CRITICAL: Commit configuration
captureSession?.commitConfiguration()

// 8. Start running on background thread
DispatchQueue.global(qos: .userInitiated).async {
    self.captureSession?.startRunning()
}
```

**Startup/Teardown Safety Rule**:
- Trigger camera setup from a single lifecycle path (avoid duplicate `checkPermissions()` calls for the same view presentation).
- Call `startRunning()` only once per configured session startup path.
- Guard setup with a dedicated in-flight flag (e.g. `isSettingUpSession`) so repeated permission callbacks/onAppear events cannot run parallel setup work.
- Attach/bind `AVCaptureVideoPreviewLayer` only after `startRunning()` completes to avoid concurrent session mutations during startup.
- During teardown, prefer `stopRunning()` + releasing references over removing inputs/outputs while the session may still be transitioning states.

**Why `beginConfiguration()` / `commitConfiguration()`?**

AVCaptureSession maintains internal arrays of inputs/outputs. When you call `addInput()` or `addOutput()`, it mutates these arrays. If the session is actively running or if another thread is enumerating these arrays (for validation, etc.), you get collection mutation crash.

`beginConfiguration()` tells the session: "I'm about to make multiple changes, don't validate or enumerate until I'm done."

`commitConfiguration()` tells the session: "I'm done, now validate everything and update internal state."

**Recording Flow**:

```swift
// Start recording
videoOutput.startRecording(to: tempURL, recordingDelegate: self)

// Delegate callback when done
func fileOutput(_ output: AVCaptureFileOutput,
                didFinishRecordingTo outputFileURL: URL,
                from connections: [AVCaptureConnection],
                error: Error?) {
    DispatchQueue.main.async {
        self.onRecordingComplete?(outputFileURL)
    }
}
```

**Temporary File Strategy**:
- Record to temp directory: `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")`
- On completion: Copy to permanent location
- Why? If recording fails, temp file is auto-cleaned by OS

### Speech Transcription (Speech Framework)

Speech transcription in `VideoRecordingView` is implemented with Apple's `Speech` framework and runs in the background during recording:

1. Request speech auth with `SFSpeechRecognizer.requestAuthorization`.
2. Keep camera/video recording on `AVCaptureMovieFileOutput`.
3. Add `AVCaptureAudioDataOutput` to the same capture session and stream sample buffers to speech recognition.
4. Feed sample buffers into `SFSpeechAudioBufferRecognitionRequest` (`appendAudioSampleBuffer`).
5. Build partial + committed transcript text while recording (no live caption overlay rendered).
6. Finalize transcript on stop and persist it as `transcript.md` in that entry's video directory.

Key details:
- Camera, microphone, and speech recognition permissions are all required before opening the recorder.
- If any permission is denied, the app keeps the user in the writing view and shows a compact camera-icon popover with the missing permission(s).
- Transcription is started on recording start and stopped on recording stop.
- Final transcript formatting is applied at stop to improve readability before saving/copying.
- Video playback nav exposes `Copy Transcript` for saved video entries with a transcript file.
- App sandbox requires `com.apple.security.personal-information.speech-recognition` entitlement plus `NSSpeechRecognitionUsageDescription`.

### Video Thumbnail Generation Nuances

```swift
func generateVideoThumbnail(from url: URL) -> NSImage? {
    let asset = AVAsset(url: url)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true  // CRITICAL

    let cgImage = try imageGenerator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 1), ...)
    return NSImage(cgImage: cgImage, size: NSSize(...))
}
```

**`appliesPreferredTrackTransform = true`**:

Videos recorded on front-facing camera are often rotated 90°. The video file contains a transform matrix that says "rotate this video when playing." Without `appliesPreferredTrackTransform`, the thumbnail would be sideways.

**Performance Note**: Thumbnails are generated once when a recording is saved and persisted as `thumbnail.jpg` in each entry's video directory. Sidebar rows load precomputed image files instead of extracting frames from `.mov` during render. For older entries without thumbnails, the app lazily generates once and saves for subsequent loads.

### Text Editor Header Behavior

Every entry starts with `\n\n` (two newlines):

```swift
TextEditor(text: Binding(
    get: { text },
    set: { newValue in
        if !newValue.hasPrefix("\n\n") {
            text = "\n\n" + newValue.trimmingCharacters(in: .newlines)
        } else {
            text = newValue
        }
    }
))
```

**Why?** Creates visual breathing room at top of page. All entries look like they start mid-page, not cramped at the top edge.

`MarkdownEditor` applies heading attributes as soon as a line matches `# `,
`## `, or `### `, even before title text is entered. Keep the matcher tolerant of
an empty heading body (`.*`, not `.+`) so the space keystroke updates the style
immediately.

### Entry Creation Logic

**Complex Decision Tree**:

```swift
if entries.isEmpty {
    // First time user → create welcome entry
    createNewEntry()
} else if !hasEmptyEntryToday && !hasOnlyWelcomeEntry {
    // No empty entry for today → create new entry
    createNewEntry()
} else {
    // Select most recent empty entry from today
    if let todayEntry = entries.first(where: { isFromTodayAndEmpty }) {
        selectedEntryId = todayEntry.id
        loadEntry(entry: todayEntry)
    } else if hasOnlyWelcomeEntry {
        // Only have welcome entry → select it
        selectedEntryId = entries[0].id
        loadEntry(entry: entries[0])
    }
}
```

**Date Comparison Complexity**:

Display dates are "MMM d" (e.g., "Feb 20") without year. To check "is this from today?":

```swift
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "MMM d"
if let entryDate = dateFormatter.date(from: entry.date) {
    // entryDate is now "Feb 20" in year 1 (default year)
    // Need to add current year to compare
    var components = calendar.dateComponents([.year, .month, .day], from: entryDate)
    components.year = calendar.component(.year, from: Date())

    if let entryDateWithYear = calendar.date(from: components) {
        let entryDayStart = calendar.startOfDay(for: entryDateWithYear)
        let todayStart = calendar.startOfDay(for: Date())
        return calendar.isDate(entryDayStart, inSameDayAs: todayStart)
    }
}
```

This handles edge cases like February 29th on non-leap years.

### Font System

**Available Fonts**:
```swift
let standardFonts = ["Lato-Regular", "Arial", ".AppleSystemUIFont", "Times New Roman"]
let availableFonts = NSFontManager.shared.availableFontFamilies
```

**Random Font Button**:
- Picks random font from `availableFonts` (excludes standardFonts)
- Shows current random font in button: "Random [FontName]"
- Clicking again picks new random font

**Font Rendering**:
```swift
.font(.custom(selectedFont, size: fontSize))
```

`.custom()` falls back to system font if font not found, so app is resilient to missing fonts.

### Line Spacing Calculation

```swift
var lineHeight: CGFloat {
    let font = NSFont(name: selectedFont, size: fontSize) ?? .systemFont(ofSize: fontSize)
    let defaultLineHeight = getLineHeight(font: font)
    return (fontSize * 1.5) - defaultLineHeight
}

func getLineHeight(font: NSFont) -> CGFloat {
    let layoutManager = NSLayoutManager()
    return layoutManager.defaultLineHeight(for: font)
}
```

**Formula**: Target line height is 1.5× font size. Subtract natural line height to get spacing to add.

Example: 18px font → target 27px line height → natural 21px → add 6px spacing

This creates **generous vertical rhythm** for readability during long writing sessions.

### Native AI Chat Panel

`AIChatPanel` is a 610-point right-side panel inspired by Jungle's interaction
contract, but adapted to Freewrite's local-first note model. Opening it starts a
new note-aware conversation and immediately generates a private-prompted
old-friend reflection (including a useful invitation for a blank note).
`ContentView` supplies the selected note or video transcript on every turn.
Switching entries selects the latest chat attached to that entry; New Chat
starts and opens another thread without changing the note. The header expansion
control lets the panel replace the editor at full window width and collapse back
without changing conversation state.

**Client layers:**
- `AIChatManager`: selected conversation, automatic opening turn, batched
  streaming reducer (120 ms UI cadence), persisted model/effort/observability
  settings, error/cancel state, and typed tool/citation/image/usage events.
- `AIChatClient`: authenticated POST SSE client for `/chat/stream`.
- `AIConversationStore`: atomic local JSON persistence on a dedicated actor and
  a unified history index over text conversations and saved voice sessions.
- `AIChatPanel`: chat/history/voice-transcript surfaces, auto-growing composer
  with in-box Call and Send controls, model menus, HTML responses, source/image
  artifacts, usage hover breakdowns, and toggleable observability. Return sends.
  Message views stay mounted in a non-lazy stack so WebKit state is not recycled.
- `AIHTMLArtifactView`: one persistent, non-persistent-data, CSP-restricted
  `WKWebView` per assistant artifact. During generation it renders sanitized
  partial HTML through throttled DOM patches with model scripts disabled; when
  complete it loads the final artifact once and enables inline interactions.
  AppKit intrinsic sizing replaces SwiftUI height bindings, and wheel events
  over WebKit are forwarded to the outer chat scroller so there is one vertical
  scroll owner. It blocks network fetches, frames, forms, local navigation, and
  non-user-initiated external-window requests. Because an artifact is embedded
  in a conversation rather than owning a browser viewport, `min-height:100vh`
  is normalized at the embed boundary to prevent expanded-panel whitespace.

Opening or switching into a chat scrolls to its bottom so the composer handoff
is visible. Submitting a user message then scrolls that message to the top of the
chat viewport. Token arrival and response completion never force another scroll,
so a reader's manual position is stable. The submit control sits immediately
left of the Call control, which is always the composer's trailing action.

After a new conversation's old-friend reflection completes, the manager starts
a separate `questions` model turn. The Soul remains the fixed system layer and
the dedicated reflection-question rubric is the most specific instruction. The
Worker returns a strict six-question JSON envelope, not HTML. Questions, their
opening-assistant-message anchor, and the second call's usage/cost are persisted
on `AIConversation`. The distinct “Reflection questions to go deeper” card is
rendered immediately after that anchored opening reflection, never as a floating
footer after later replies. A pencil action appends the question to the current
note as an H3, adds viewport-proportional trailing writing space, focuses the
editor below the question, and scrolls the question near the top of the visible
page. A call action carries that question into voice as the chosen starting
point. The request includes the current note plus bounded snapshots of up to six
recent Freewrite entries. It must never imply it read Obsidian notes unless such
notes are actually supplied.

When a voice session ends, local transcript persistence completes first and an
idempotent `AIVoiceCallSummary` message is appended to the note's text
conversation with the call duration. The optional Supabase transcript upload is
best-effort background work and must not delay the ended phase or completed-call
card. Voice call summary messages are display-only and are excluded from model
history.

**Worker loop:** `backend/voice-token-worker/src/chat.ts` verifies the Supabase
ES256 JWT before work, rate-limits by verified user ID, validates and caps the
request, then drives a bounded OpenAI Responses or Anthropic Messages tool loop.
The event contract is `text-delta`, `text-reset`, `tool-start`, `tool-result`,
`citation`, `usage`, `finish`, and `error`. At the tool-step cap it makes a final
tool-free model call so a turn cannot end on an unanswered tool request. The
Worker is stateless: recent chat history and latest note context are supplied
each turn. OpenAI Responses use `store: false`; Anthropic replays the explicit
history and handles `pause_turn` continuation with the same tool definitions.
The chat loop permits at most three client-tool rounds and one tool per Anthropic
response, and caps output at 7,000 tokens so pathological tool/reasoning loops
cannot hold the panel indefinitely.

Before transport, `AIChatRequestCompactor` keeps the latest note tail within a
byte budget and converts prior assistant HTML artifacts back to visible text.
This prevents CSS/JavaScript token waste and keeps long conversations under the
Worker's 96 KB authenticated request limit without changing locally saved HTML.
Switching notes invalidates the active chat operation before selecting or
opening the destination conversation. Every post-await and streaming mutation
is operation-ID guarded so a canceled prior-note stream cannot overwrite the
new selection or clear the new task handle.

OpenAI replay is role-aware: user turns use `input_text`, while assistant turns
use `output_text`. Using `input_text` for an assistant history item makes a
follow-up Responses request fail inside the already-open SSE stream.

The fixed Soul is the fundamental system layer. A hidden old-friend prompt is
the immediate opening turn, and the HTML-artifact instruction is the exact end
of every system prompt. Assistant responses are raw, self-contained HTML; never
persist the hidden opening prompt as a visible user message. The Worker also
enforces that contract after streaming: valid full artifacts pass through,
fragments receive a document shell, and plain text receives a deterministic,
escaped HTML artifact through `text-reset` before finish.
Reflection-question turns use provider-enforced structured output. OpenAI emits
the stable six-item array directly; Anthropic emits six required named fields
because its raw schema does not support exact array cardinality, then the Worker
normalizes them to the same `{ "questions": string[] }` client contract before
finish.

**Tools:**
- OpenAI or Anthropic hosted `web_search` for current/external facts and linked
  citations. Anthropic uses basic `web_search_20250305`; newer dynamic-filtering
  variants can invoke internal bash/text-editor helpers. Provider-internal tools
  are never surfaced, persisted, or left running in product UI, and ordinary
  journal/reflection follow-ups receive no tools at all. The Worker offers only
  request-relevant tools, based on explicit web/current-fact, image, URL, or
  current-note-search intent; an explicit “do not search” wins over keywords.
- `search_current_note` for exact passages in long notes (local Worker search).
- `image_search` for public reference images via Wikimedia Commons; results are
  rendered as linked image cards in the panel.
- `read_url` via Jina Reader for a specific public HTTP(S) page, with private/
  localhost targets rejected, upstream timeouts, and bounded response reads.

Tools return structured errors instead of throwing through the whole turn, and
tool activity is visible only while observability is enabled.
The default text model is GPT-5.6 Terra with low reasoning for latency. GPT-5.6
Sol, Claude Sonnet 5, Claude Opus 4.8, Claude Fable 5, and provider-valid effort
levels are selectable in the composer. Anthropic models require the Worker's
optional `ANTHROPIC_API_KEY`; missing configuration returns HTTP 409 instead of
silently changing models. Token and cost labels expose hover breakdowns for
input/cache-write/cached/output/reasoning/search components. Costs are
list-price estimates and must not be treated as billing truth.

### Prompts

The bottom-center `prompts` control opens a local prompt palette over the editor.
Prompts can be one-time (removed after insertion) or recurring, can be renamed,
deleted, and reordered within their section, and insert as an H2 at the current
editor cursor. Insertions are recorded in searchable prompt history. Prompt data
lives in `~/Library/Application Support/freewrite/prompts.json` and
`prompt_history.json`; writing entries remain unchanged in
`~/Documents/Freewrite/`.

Command-P toggles the palette while Freewrite is active. The Carbon-based global
Command-Shift-P hotkey activates the existing app window and focuses the add
field. `EditorController` is the narrow bridge for insertion/focus; do not route
cursor state through the SwiftUI text binding. The editor disables interaction
while the palette is open so clicks do not leak through the overlay.

### PDF Export Implementation

```swift
func exportEntryAsPDF(entry: HumanEntry) {
    let savePanel = NSSavePanel()
    savePanel.title = extractTitleFromContent(content, date: entry.date)
    savePanel.allowedContentTypes = [.pdf]

    if savePanel.runModal() == .OK {
        let pdfData = createPDF(from: content)
        try pdfData.write(to: savePanel.url!)
    }
}
```

**Title Extraction**:
- Takes first 4 words of content
- Removes punctuation
- Falls back to "Entry [date]" if content empty

### Theme System

```swift
@State private var colorScheme: ColorScheme = .light

// Apply to entire window
.preferredColorScheme(colorScheme)

// Persisted to UserDefaults
UserDefaults.standard.set(colorScheme == .light ? "light" : "dark", forKey: "colorScheme")
```

**Colors**:
- Light mode text: `Color(red: 0.20, green: 0.20, blue: 0.20)` (dark gray, not black, easier on eyes)
- Dark mode text: `Color(red: 0.9, green: 0.9, blue: 0.9)` (off-white, not pure white)

## Common Pitfalls

### Collection Mutation Crashes

**Problem**: Modifying `entries` array while SwiftUI is enumerating it.

**Solution**:
```swift
// BAD
entries.insert(newEntry, at: 0)

// GOOD (from async context)
DispatchQueue.main.async {
    self.entries.insert(newEntry, at: 0)
}
```

### AVCaptureSession Crashes

**Problem**: Session internals can crash with `Collection ... was mutated while being enumerated` when session startup/teardown overlaps (for example duplicate setup/start calls or mutating inputs/outputs during active transitions).

**Solution**:
```swift
captureSession?.beginConfiguration()
// Add/remove inputs and outputs here
captureSession?.sessionPreset = .high
captureSession?.addInput(videoInput)
captureSession?.commitConfiguration()
```

Also:
```swift
// Avoid duplicate startup paths for the same presentation
// and avoid repeated startRunning() calls on the same setup cycle.

if session.isRunning {
    session.stopRunning()
}
// Release session/output references without input/output removal churn.
```

### File Path Issues

Always use absolute paths:
```swift
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Freewrite")
let fileURL = documentsDirectory.appendingPathComponent(filename)
```

## Build Configuration

**Scheme**: freewrite
**Configuration**: Debug or Release
**Build Command**:
```bash
xcodebuild -project freewrite.xcodeproj -scheme freewrite -configuration Debug build
```

**Clean Build**:
```bash
xcodebuild -project freewrite.xcodeproj -scheme freewrite -configuration Debug clean build
```

## Testing Video Feature

1. Build and run app
2. Grant camera/microphone permissions when prompted
3. Click video camera icon in bottom nav
4. Click "Start Recording" (turns red)
5. Record for a few seconds
6. Click "Stop Recording"
7. Recorder overlay closes, new video entry is selected, and video opens immediately playing muted
8. Click video entry to play it

## Video Thumbnail Generation

```swift
func generateVideoThumbnail(from url: URL) -> NSImage? {
    let asset = AVAsset(url: url)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true

    let cgImage = try imageGenerator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 1), actualTime: nil)
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}
```

Generated at save time and stored in the per-entry video directory; sidebar loads this cached image file.

## Feature Flags / Settings

Stored in `UserDefaults`:
- `colorScheme`: "light" or "dark"

Other settings are session-only (not persisted):
- Font size, font family, timer duration, backspace state

## Future Development Notes

### Adding New Entry Types

1. Add case to `EntryType` enum
2. Update `HumanEntry` with relevant properties
3. Modify `loadExistingEntries()` to detect new file type
4. Update `loadEntry()` to handle new type
5. Add UI in main view for new entry type
6. Update `deleteEntry()` to clean up new file types

### Adding New Navigation Items

Add to bottom nav in ContentView.swift around line 500-950:

```swift
Text("•")
    .foregroundColor(.gray)

Button(action: {
    // Your action
}) {
    Image(systemName: "icon.name") // or Text("Label")
        .foregroundColor(isHovering ? textHoverColor : textColor)
}
.buttonStyle(.plain)
.onHover { hovering in
    isHovering = hovering
    isHoveringBottomNav = hovering
    if hovering {
        NSCursor.pointingHand.push()
    } else {
        NSCursor.pop()
    }
}
```

## Debugging

Enable console output in Xcode to see:
- File loading: "Processing: [filename]"
- Entry creation: "Successfully created video entry"
- Errors: "Error saving video entry: ..."

Check `~/Documents/Freewrite/` in Finder to verify files are being created.

## Code Organization

- **Lines 1-130**: Imports, models, state variables
- **Lines 130-430**: Computed properties and helpers
- **Lines 430-1200**: Main view body and UI
- **Lines 1200-1400**: Helper functions (save, load, delete, etc.)

## Key SwiftUI Patterns Used

- `@State` for local view state
- `@StateObject` for CameraManager
- `.overlay { if showingVideoRecording { ... } }` for immersive video recording
- `.onChange(of:)` for auto-save
- `.onAppear` for initialization
- `ForEach(entries)` with `Identifiable` for list rendering
- Conditional views: `if currentVideoURL != nil { VideoPlayerView } else { TextEditor }`

## Voice Coach (AI voice conversations)

A "Voice" button (bottom nav, next to Chat) starts a spoken AI-coaching call
seeded with the current entry (text body, or a video entry's transcript). Voice
setup and the active call now replace chat inside the same 610-point/full-width
AI surface; they are not a separate sheet or window-filling overlay. Calls
started from chat also receive a bounded visible-text replay of the text
conversation. Calls started from a reflection-question card receive that
question as the explicit opener and focus.

**Architecture:** The Voice button opens a persisted pre-call Voice Lab. Its
versioned `VoiceSessionConfiguration` flows through `VoiceTokenClient` → the
Cloudflare Worker (Supabase ES256/JWKS + audience/role verification, schema
validation, per-user rate limiting, opaque room name, microphone-only grant) →
LiveKit metadata → the Python agent. Unknown profiles are rejected at both
boundaries; never silently fall back during model comparisons.
The Worker's non-secret `ENABLED_VOICE_PROVIDERS` and
`ENABLED_STRATEGIST_PROVIDERS` must mirror keys on the active agent. It rejects
unavailable selections with HTTP 409 before minting a room. The macOS client
considers the coach ready only after an agent-state or lifecycle-ready signal,
not merely when the transient RTC agent participant appears; configuration
errors are published over telemetry before the failed job exits.

Two architectures share the exact same prompt builder in `coach/prompt.py`:

- **Cascade (default):** Deepgram Nova-3 → selected text LLM → ElevenLabs
  `eleven_flash_v2_5`, with Silero VAD and LiveKit 1.6's acoustic + semantic
  `TurnDetector`. Flux is an optional English A/B mode that owns EOT; it is not
  default because its main value overlaps the new LiveKit detector.
- **Native realtime:** GPT-Realtime 2.1/mini, Gemini 3.1 Flash Live Preview, or
  Grok Voice owns audio input, reasoning, turn-taking, and audio output.

The profile catalogs in Swift, TypeScript, and Python must keep identical IDs.
Google and OpenAI profiles work with the current local secrets; Anthropic and
xAI profiles require their corresponding agent environment keys.

**Dual-model coaching:** `DeliberationCoordinator` asynchronously analyzes
changed transcript turns every 15/20/30 seconds (30 by default) with a selected
Gemini, Claude Sonnet 5, Claude Opus 4.8, or GPT-5.6 Sol model and selectable
provider-valid thinking effort. It emits a concise structured `CoachingBrief`
(not chain-of-thought), injects the full brief into the next response's system
context for providers supporting dynamic instructions, and exposes the same
brief through `get_coaching_brief`. The injection/fallback result is published
with the brief for observability. Gemini 3.1 Live cannot reliably accept
`generate_reply`, instructions, or chat-context updates after turn one, so it
starts by listening and uses the tool-only strategist fallback.

**Observability:** the agent publishes config, lifecycle, transcript, per-turn
latency, sampled cumulative provider usage/cost estimates, errors, and briefs over the
reliable `freewrite.voice.telemetry` data topic. `VoiceObservabilityPanel` is
toggleable during a call. Session end writes `transcript.md`, `meta.json`,
`events.json`, and `analyses.json` under
`~/Documents/Freewrite/VoiceSessions/`, plus a migration-safe Supabase
`voice_sessions` row under RLS. LiveKit Cloud remains the durable trace/audio
recording surface. Costs are list-price estimates, not billing truth.

**Voice canvas:** the default in-call view keeps visual artifacts separate from
spoken prose, following Jungle's data-channel pattern. It shows the current
question and relevant image artifacts; an eye toggle reveals/hides the full
user/AI transcript. The agent's bounded `image_search` tool queries Wikimedia,
publishes a selected image over reliable `freewrite.voice.artifact`, and emits
its tool duration/status to normal observability. Chat image-search results are
also available on handoff. The transcript remains plain spoken content.

> **⚠️ NOT PROD-READY — the agent runs locally.** The coach agent is a local
> process on Julian's Mac, kept alive by a launchd LaunchAgent
> (`~/Library/LaunchAgents/ai.julian.freewrite-coach.plist`; logs at
> `/tmp/freewrite-coach.log`). This is intentional for fast iteration.
> **Shipping to anyone else requires deploying the agent to LiveKit Cloud**
> (`lk agent deploy`; Dockerfile ready) — see the deploy checklist in
> `backend/voice-coach-agent/README.md`, then unload the LaunchAgent so local
> and cloud don't both serve dispatches.

**Debugging:** filter app console on `[VoiceCoach]` (full lifecycle is logged).
"Coach doesn't speak" → run the headless probe
`backend/voice-coach-agent/tools/e2e_probe.py` — it joins like the app and
measures actual agent audio. Use `--profile` to choose a model and
`--user-utterance` for listen-first Gemini Live.

**Hard-won gotchas (do not regress):**
- LiveKit's default AVAudioEngine audio module fails on this Mac
  (`kAUStartIO error 35`); `VoiceCoachManager` must set
  `AudioManager.set(audioDeviceModuleType: .platformDefault)` before the first
  `Room`.
- App Sandbox must stay OFF — it blocks LiveKit's regional WebSocket failover
  ("Region manager error (No more remaining regions)").
- Supabase auth session is stored in a FILE (`FileAuthLocalStorage`), not the
  keychain — ad-hoc dev signatures change every build, so keychain "Always
  Allow" can never stick. Keep `emitLocalSessionAsInitialSession: true`, check
  `Session.isExpired`, and re-open Google sign-in when `currentToken()` cannot
  refresh; otherwise an expired disk session can produce misleading 401s.
  Concurrent sign-in callers must share `OAuthSignInCoordinator`; replacing a
  pending callback continuation strands the earlier caller.
- Fatal coach configuration, non-recoverable agent-session telemetry errors,
  and unexpected coach disconnects in any active room phase must cancel level
  polling and disconnect the LiveKit room so a failed call cannot leave the
  microphone published. Supervisor and recoverable provider errors remain
  visible in observability without ending an otherwise live call.
- LiveKit participant metadata with an explicit invalid `voiceConfig` must
  publish a configuration error and stop. Never silently benchmark a fallback
  model when the selected profile or controls are invalid.
- The ElevenLabs plugin reads `ELEVEN_API_KEY` (not `ELEVENLABS_API_KEY`).
- The token Worker is the model-routing boundary. App-side catalog changes do
  nothing until the same ID exists in Worker + agent and the Worker is deployed.
- `metrics_collected` is deprecated in LiveKit 1.6; use
  `session_usage_updated` for cumulative usage/cost and `ChatMessage.metrics`
  for per-turn latency. Metrics may be dataclasses rather than mappings; pass
  them through `coach.telemetry.jsonable` instead of calling `dict(...)`.
- LiveKit 1.6 turn controls belong under `turn_handling` (`turn_detection`,
  `endpointing`, `interruption`, and `preemptive_generation`); the old flat
  `AgentSession` options are deprecated and scheduled for removal in 2.0.
- The `freewrite://` URL scheme (OAuth callback) is registered via the partial
  `freewrite/Info.plist` merged with `GENERATE_INFOPLIST_FILE` — don't remove
  either half.
- Call sounds (calling loop / answered / hang-up, ported from Jungle) are
  driven by phase transitions in `VoiceCallSounds.swift`.

## Summary

Freewrite is a local-first macOS writing app with video journaling and optional
authenticated AI text/voice services. Notes and conversation history remain
plain local files; AI inference, web tools, and LiveKit voice require their
backends. The main complexity is in:

1. Proper file management and UUID-based naming
2. Thread-safe array mutations for entries
3. AVFoundation camera setup with proper configuration blocks
4. Conditional rendering between text and video content
5. Authenticated streaming text/voice sessions and durable local conversation history

When making changes, always:
- Test with actual video recording
- Check for collection mutation crashes
- Verify files are created in correct location
- Ensure privacy permissions are properly configured
