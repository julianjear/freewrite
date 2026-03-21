// Swift 5.0
//
//  ContentView.swift
//  freewrite
//
//  Created by thorfinn on 2/14/25.
//  Modified with: custom folder support, human-readable filenames,
//  timer presets, bottom padding fix, rename-safe file identity.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

struct HumanEntry: Identifiable {
    let id: UUID
    let createdDate: Date
    let displayDate: String
    var filename: String
    var previewText: String
    
    static func createNew(in directory: URL) -> HumanEntry {
        let id = UUID()
        let now = Date()
        let dateFormatter = DateFormatter()
        
        // Format: "Feb, 9, 2026 - freewrite"
        dateFormatter.dateFormat = "MMM"
        let month = dateFormatter.string(from: now)
        let day = Calendar.current.component(.day, from: now)
        let year = Calendar.current.component(.year, from: now)
        
        let baseFilename = "\(month), \(day), \(year) - freewrite"
        var filename = "\(baseFilename).md"
        
        // Handle duplicates on the same day
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
            filename = "\(baseFilename) \(counter).md"
            counter += 1
        }
        
        // For display
        dateFormatter.dateFormat = "MMM d"
        let displayDate = dateFormatter.string(from: now)
        
        return HumanEntry(
            id: id,
            createdDate: now,
            displayDate: displayDate,
            filename: filename,
            previewText: ""
        )
    }
}

struct HeartEmoji: Identifiable {
    let id = UUID()
    var position: CGPoint
    var offset: CGFloat = 0
}

struct ContentView: View {
    @State private var entries: [HumanEntry] = []
    @State private var text: String = ""
    @AppStorage("customDirectoryPath") private var customDirectoryPath: String = ""
    
    @State private var isFullscreen = false
    @State private var selectedFont: String = "Lato-Regular"
    @State private var currentRandomFont: String = ""
    @State private var timeRemaining: Int = 900
    @State private var timerIsRunning = false
    @State private var isHoveringTimer = false
    @State private var isHoveringFullscreen = false
    @State private var hoveredFont: String? = nil
    @State private var isHoveringSize = false
    @State private var fontSize: CGFloat = 18
    @State private var blinkCount = 0
    @State private var isBlinking = false
    @State private var opacity: Double = 1.0
    @State private var shouldShowGray = true
    @State private var lastClickTime: Date? = nil
    @State private var bottomNavOpacity: Double = 1.0
    @State private var isHoveringBottomNav = false
    @State private var selectedEntryIndex: Int = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedEntryId: UUID? = nil
    @State private var hoveredEntryId: UUID? = nil
    @State private var isHoveringChat = false
    @State private var showingChatMenu = false
    @State private var showingTimerMenu = false
    @State private var chatMenuAnchor: CGPoint = .zero
    @State private var showingSidebar = false
    @State private var hoveredTrashId: UUID? = nil
    @State private var hoveredExportId: UUID? = nil
    @State private var placeholderText: String = ""
    @State private var isHoveringNewEntry = false
    @State private var isHoveringClock = false
    @State private var isHoveringHistory = false
    @State private var isHoveringHistoryText = false
    @State private var isHoveringHistoryPath = false
    @State private var isHoveringHistoryArrow = false
    @State private var colorScheme: ColorScheme = .light
    @State private var isHoveringThemeToggle = false
    @State private var didCopyPrompt: Bool = false
    @State private var backspaceDisabled = false
    @State private var isHoveringBackspaceToggle = false
    @State private var isHoveringFolderButton = false
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    let entryHeight: CGFloat = 40
    
    let availableFonts = NSFontManager.shared.availableFontFamilies
    let standardFonts = ["Lato-Regular", "Arial", ".AppleSystemUIFont", "Times New Roman"]
    let fontSizes: [CGFloat] = [16, 18, 20, 22, 24, 26]
    let placeholderText_default = "start free flowing..."
    
    // File manager and save timer
    private let fileManager = FileManager.default
    private let saveTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    // Documents directory with custom path support
    private var documentsDirectory: URL {
        if !customDirectoryPath.isEmpty {
            let url = URL(fileURLWithPath: customDirectoryPath)
            if !fileManager.fileExists(atPath: url.path) {
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
        
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Freewrite")
        
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                print("Successfully created Freewrite directory")
            } catch {
                print("Error creating directory: \(error)")
            }
        }
        
        return directory
    }
    
    // Shared prompt constant
    private let aiChatPrompt = """
    below is my journal entry. wyt? talk through it with me like a friend. don't therpaize me and give me a whole breakdown, don't repeat my thoughts with headings. really take all of this, and tell me back stuff truly as if you're an old homie.
    
    Keep it casual, dont say yo, help me make new connections i don't see, comfort, validate, challenge, all of it. dont be afraid to say a lot. format with markdown headings if needed.

    do not just go through every single thing i say, and say it back to me. you need to proccess everythikng is say, make connections i don't see it, and deliver it all back to me as a story that makes me feel what you think i wanna feel. thats what the best therapists do.

    ideally, you're style/tone should sound like the user themselves. it's as if the user is hearing their own tone but it should still feel different, because you have different things to say and don't just repeat back they say.

    else, start by saying, "hey, thanks for showing me this. my thoughts:"
        
    my entry:
    """
    
    private let claudePrompt = """
    Take a look at my journal entry below. I'd like you to analyze it and respond with deep insight that feels personal, not clinical.
    Imagine you're not just a friend, but a mentor who truly gets both my tech background and my psychological patterns. I want you to uncover the deeper meaning and emotional undercurrents behind my scattered thoughts.
    Keep it casual, dont say yo, help me make new connections i don't see, comfort, validate, challenge, all of it. dont be afraid to say a lot. format with markdown headings if needed.
    Use vivid metaphors and powerful imagery to help me see what I'm really building. Organize your thoughts with meaningful headings that create a narrative journey through my ideas.
    Don't just validate my thoughts - reframe them in a way that shows me what I'm really seeking beneath the surface. Go beyond the product concepts to the emotional core of what I'm trying to solve.
    Be willing to be profound and philosophical without sounding like you're giving therapy. I want someone who can see the patterns I can't see myself and articulate them in a way that feels like an epiphany.
    Start with 'hey, thanks for showing me this. my thoughts:' and then use markdown headings to structure your response.

    Here's my journal entry:
    """
    
    // Initialize with saved theme preference
    init() {
        let savedScheme = UserDefaults.standard.string(forKey: "colorScheme") ?? "light"
        _colorScheme = State(initialValue: savedScheme == "dark" ? .dark : .light)
    }
    
    private func getDocumentsDirectory() -> URL {
        return documentsDirectory
    }
    
    private func saveText() {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent("entry.md")
        
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Error saving file: \(error)")
        }
    }
    
    private func loadText() {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent("entry.md")
        
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                text = try String(contentsOf: fileURL, encoding: .utf8)
            }
        } catch {
            print("Error loading file: \(error)")
        }
    }
    
    // MARK: - File Migration
    
    /// Migrates old-format filenames ([UUID]-[date].md) to human-readable format (MMM, d, yyyy - freewrite.md)
    private func migrateOldFilenames() {
        let directory = documentsDirectory
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            let mdFiles = fileURLs.filter { $0.pathExtension == "md" }
            
            for fileURL in mdFiles {
                let filename = fileURL.lastPathComponent
                
                // Check if it matches old pattern [UUID]-[date].md
                guard filename.range(of: "^\\[.*\\]-\\[\\d{4}-\\d{2}-\\d{2}-\\d{2}-\\d{2}-\\d{2}\\]\\.md$", options: .regularExpression) != nil else {
                    continue
                }
                
                // Parse date from old filename
                let dateFormatter = DateFormatter()
                if let dateMatch = filename.range(of: "\\[(\\d{4}-\\d{2}-\\d{2}-\\d{2}-\\d{2}-\\d{2})\\]", options: .regularExpression) {
                    let dateString = String(filename[dateMatch].dropFirst().dropLast())
                    dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
                    
                    if let fileDate = dateFormatter.date(from: dateString) {
                        dateFormatter.dateFormat = "MMM"
                        let month = dateFormatter.string(from: fileDate)
                        let day = Calendar.current.component(.day, from: fileDate)
                        let year = Calendar.current.component(.year, from: fileDate)
                        
                        let baseFilename = "\(month), \(day), \(year) - freewrite"
                        var newFilename = "\(baseFilename).md"
                        var counter = 2
                        while fileManager.fileExists(atPath: directory.appendingPathComponent(newFilename).path) {
                            newFilename = "\(baseFilename) \(counter).md"
                            counter += 1
                        }
                        
                        let newURL = directory.appendingPathComponent(newFilename)
                        try fileManager.moveItem(at: fileURL, to: newURL)
                        print("Migrated: \(filename) → \(newFilename)")
                    }
                }
            }
        } catch {
            print("Migration error: \(error)")
        }
    }
    
    // MARK: - Custom Folder
    
    private func selectCustomDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to store your Freewrite notes"
        panel.prompt = "Choose"
        
        panel.begin { response in
            if response == .OK, let url = panel.urls.first {
                customDirectoryPath = url.path
                loadExistingEntries()
            }
        }
    }
    
    private func resetToDefaultDirectory() {
        customDirectoryPath = ""
        loadExistingEntries()
    }
    
    // MARK: - Entry Loading
    
    /// Loads entries from disk. Uses file creation dates instead of parsing filenames,
    /// so renaming files won't break anything.
    private func loadExistingEntries() {
        let directory = documentsDirectory
        print("Looking for entries in: \(directory.path)")
        
        // Migrate old-format filenames first
        migrateOldFilenames()
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            let mdFiles = fileURLs.filter { $0.pathExtension == "md" }
            
            print("Found \(mdFiles.count) .md files")
            
            let entriesWithDates = mdFiles.compactMap { fileURL -> (entry: HumanEntry, date: Date, content: String)? in
                let filename = fileURL.lastPathComponent
                
                // Get creation date from file attributes (not filename)
                let resourceValues = try? fileURL.resourceValues(forKeys: [.creationDateKey])
                let createdDate = resourceValues?.creationDate ?? Date()
                
                do {
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    let preview = content
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let truncated = preview.isEmpty ? "" : (preview.count > 30 ? String(preview.prefix(30)) + "..." : preview)
                    
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MMM d"
                    let displayDate = dateFormatter.string(from: createdDate)
                    
                    return (
                        entry: HumanEntry(
                            id: UUID(),
                            createdDate: createdDate,
                            displayDate: displayDate,
                            filename: filename,
                            previewText: truncated
                        ),
                        date: createdDate,
                        content: content
                    )
                } catch {
                    print("Error reading file \(filename): \(error)")
                    return nil
                }
            }
            
            entries = entriesWithDates
                .sorted { $0.date > $1.date }
                .map { $0.entry }
            
            print("Successfully loaded and sorted \(entries.count) entries")
            
            let calendar = Calendar.current
            let today = Date()
            
            // Using createdDate directly — no more fragile date string parsing
            let hasEmptyEntryToday = entries.contains { entry in
                calendar.isDate(entry.createdDate, inSameDayAs: today) && entry.previewText.isEmpty
            }
            
            let hasOnlyWelcomeEntry = entries.count == 1 && entriesWithDates.first?.content.contains("Welcome to Freewrite.") == true
            
            if entries.isEmpty {
                print("First time user, creating welcome entry")
                createNewEntry()
            } else if !hasEmptyEntryToday && !hasOnlyWelcomeEntry {
                print("No empty entry for today, creating new entry")
                createNewEntry()
            } else {
                if let todayEntry = entries.first(where: { entry in
                    calendar.isDate(entry.createdDate, inSameDayAs: today) && entry.previewText.isEmpty
                }) {
                    selectedEntryId = todayEntry.id
                    loadEntry(entry: todayEntry)
                } else if hasOnlyWelcomeEntry {
                    selectedEntryId = entries[0].id
                    loadEntry(entry: entries[0])
                }
            }
            
        } catch {
            print("Error loading directory contents: \(error)")
            createNewEntry()
        }
    }
    
    var randomButtonTitle: String {
        return currentRandomFont.isEmpty ? "Random" : "Random [\(currentRandomFont)]"
    }
    
    var timerButtonTitle: String {
        if !timerIsRunning && timeRemaining == 900 {
            return "15:00"
        }
        let minutes = timeRemaining / 60
        let seconds = timeRemaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var timerColor: Color {
        if timerIsRunning {
            return isHoveringTimer ? (colorScheme == .light ? .black : .white) : .gray.opacity(0.8)
        } else {
            return isHoveringTimer ? (colorScheme == .light ? .black : .white) : (colorScheme == .light ? .gray : .gray.opacity(0.8))
        }
    }
    
    var lineHeight: CGFloat {
        let font = NSFont(name: selectedFont, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let defaultLineHeight = getLineHeight(font: font)
        return (fontSize * 1.5) - defaultLineHeight
    }
    
    var fontSizeButtonTitle: String {
        return "\(Int(fontSize))px"
    }
    
    var placeholderOffset: CGFloat {
        return fontSize
    }
    
    var popoverBackgroundColor: Color {
        return colorScheme == .light ? Color(NSColor.controlBackgroundColor) : Color(NSColor.darkGray)
    }
    
    var popoverTextColor: Color {
        return colorScheme == .light ? Color.primary : Color.white
    }

    
    var body: some View {
        let buttonBackground = colorScheme == .light ? Color.white : Color.black
        let navHeight: CGFloat = 68
        let textColor = colorScheme == .light ? Color.gray : Color.gray.opacity(0.8)
        let textHoverColor = colorScheme == .light ? Color.black : Color.white
        
        HStack(spacing: 0) {
            // Main content
            ZStack {
                Color(colorScheme == .light ? .white : .black)
                    .ignoresSafeArea()
                
                    MarkdownEditor(
                        text: $text,
                        font: NSFont(name: selectedFont, size: fontSize) ?? .systemFont(ofSize: fontSize),
                        textColor: colorScheme == .light
                            ? NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0)
                            : NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0),
                        backgroundColor: colorScheme == .light ? .white : .black,
                        lineSpacing: lineHeight
                    )
                    .frame(maxWidth: 650)
                    .id("\(selectedFont)-\(fontSize)-\(colorScheme)")
                    .padding(.bottom, bottomNavOpacity > 0 ? navHeight : 20)
                    .ignoresSafeArea()
                    .colorScheme(colorScheme)
                    .onAppear {
                        placeholderText = placeholderText_default

                        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                            if backspaceDisabled && (event.keyCode == 51 || event.keyCode == 117) {
                                return nil
                            }
                            return event
                        }
                    }
                    .overlay(
                        ZStack(alignment: .topLeading) {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(placeholderText)
                                    .font(.custom(selectedFont, size: fontSize))
                                    .foregroundColor(colorScheme == .light ? .gray.opacity(0.5) : .gray.opacity(0.6))
                                    .allowsHitTesting(false)
                                    .offset(x: 7, y: placeholderOffset)
                            }
                        }, alignment: .topLeading
                    )
                    
                
                VStack {
                    Spacer()
                    HStack {
                        // Font buttons (left)
                        HStack(spacing: 8) {
                            Button(fontSizeButtonTitle) {
                                if let currentIndex = fontSizes.firstIndex(of: fontSize) {
                                    let nextIndex = (currentIndex + 1) % fontSizes.count
                                    fontSize = fontSizes[nextIndex]
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(isHoveringSize ? textHoverColor : textColor)
                            .onHover { hovering in
                                isHoveringSize = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Button("Lato") {
                                selectedFont = "Lato-Regular"
                                currentRandomFont = ""
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(hoveredFont == "Lato" ? textHoverColor : textColor)
                            .onHover { hovering in
                                hoveredFont = hovering ? "Lato" : nil
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Button("Arial") {
                                selectedFont = "Arial"
                                currentRandomFont = ""
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(hoveredFont == "Arial" ? textHoverColor : textColor)
                            .onHover { hovering in
                                hoveredFont = hovering ? "Arial" : nil
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Button("System") {
                                selectedFont = ".AppleSystemUIFont"
                                currentRandomFont = ""
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(hoveredFont == "System" ? textHoverColor : textColor)
                            .onHover { hovering in
                                hoveredFont = hovering ? "System" : nil
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Button("Serif") {
                                selectedFont = "Times New Roman"
                                currentRandomFont = ""
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(hoveredFont == "Serif" ? textHoverColor : textColor)
                            .onHover { hovering in
                                hoveredFont = hovering ? "Serif" : nil
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Button(randomButtonTitle) {
                                if let randomFont = availableFonts.randomElement() {
                                    selectedFont = randomFont
                                    currentRandomFont = randomFont
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(hoveredFont == "Random" ? textHoverColor : textColor)
                            .onHover { hovering in
                                hoveredFont = hovering ? "Random" : nil
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        }
                        .padding(8)
                        .cornerRadius(6)
                        .onHover { hovering in
                            isHoveringBottomNav = hovering
                        }
                        
                        Spacer()
                        
                        // Utility buttons (right)
                        HStack(spacing: 8) {
                            // Timer with presets dropdown
                            HStack(spacing: 2) {
                                Button(action: {
                                    showingTimerMenu = true
                                }) {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 8))
                                        .foregroundColor(textColor)
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    isHoveringBottomNav = hovering
                                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                }
                                .popover(isPresented: $showingTimerMenu, attachmentAnchor: .point(UnitPoint(x: 0.5, y: 0)), arrowEdge: .top) {
                                    VStack(spacing: 0) {
                                        ForEach([("25:00", 1500), ("15:00", 900), ("10:00", 600), ("5:00", 300)], id: \.1) { label, seconds in
                                            Button(action: {
                                                showingTimerMenu = false
                                                timeRemaining = seconds
                                                timerIsRunning = false
                                            }) {
                                                Text(label)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 8)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundColor(popoverTextColor)
                                            .onHover { hovering in
                                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                            }
                                            if seconds != 300 { Divider() }
                                        }
                                    }
                                    .frame(width: 100)
                                    .background(popoverBackgroundColor)
                                    .cornerRadius(8)
                                    .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
                                }
                                
                                Button(timerButtonTitle) {
                                    let now = Date()
                                    if let lastClick = lastClickTime,
                                       now.timeIntervalSince(lastClick) < 0.3 {
                                        timeRemaining = 900
                                        timerIsRunning = false
                                        lastClickTime = nil
                                    } else {
                                        timerIsRunning.toggle()
                                        lastClickTime = now
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(timerColor)
                                .onHover { hovering in
                                    isHoveringTimer = hovering
                                    isHoveringBottomNav = hovering
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                                .onAppear {
                                    NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                                        if isHoveringTimer {
                                            let scrollBuffer = event.deltaY * 0.25
                                            
                                            if abs(scrollBuffer) >= 0.1 {
                                                let currentMinutes = timeRemaining / 60
                                                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                                let direction = -scrollBuffer > 0 ? 5 : -5
                                                let newMinutes = currentMinutes + direction
                                                let roundedMinutes = (newMinutes / 5) * 5
                                                let newTime = roundedMinutes * 60
                                                timeRemaining = min(max(newTime, 0), 2700)
                                            }
                                        }
                                        return event
                                    }
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Button("Chat") {
                                showingChatMenu = true
                                didCopyPrompt = false
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(isHoveringChat ? textHoverColor : textColor)
                            .onHover { hovering in
                                isHoveringChat = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            .popover(isPresented: $showingChatMenu, attachmentAnchor: .point(UnitPoint(x: 0.5, y: 0)), arrowEdge: .top) {
                                VStack(spacing: 0) {
                                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    
                                    let gptFullText = aiChatPrompt + "\n\n" + trimmedText
                                    let claudeFullText = claudePrompt + "\n\n" + trimmedText
                                    let encodedGptText = gptFullText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                                    let encodedClaudeText = claudeFullText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                                    
                                    let gptUrlLength = "https://chat.openai.com/?m=".count + encodedGptText.count
                                    let claudeUrlLength = "https://claude.ai/new?q=".count + encodedClaudeText.count
                                    let isUrlTooLong = gptUrlLength > 6000 || claudeUrlLength > 6000
                                    
                                    if isUrlTooLong {
                                        Text("Hey, your entry is quite long. You'll need to manually copy the prompt by clicking 'Copy Prompt' below and then paste it into AI of your choice (ex. ChatGPT). The prompt includes your entry as well. So just copy paste and go! See what the AI says.")
                                            .font(.system(size: 14))
                                            .foregroundColor(popoverTextColor)
                                            .lineLimit(nil)
                                            .multilineTextAlignment(.leading)
                                            .frame(width: 200, alignment: .leading)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                        
                                        Divider()
                                        
                                        Button(action: {
                                            copyPromptToClipboard()
                                            didCopyPrompt = true
                                        }) {
                                            Text(didCopyPrompt ? "Copied!" : "Copy Prompt")
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(popoverTextColor)
                                        .onHover { hovering in
                                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                        }
                                        
                                    } else if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("hi. my name is farza.") {
                                        Text("Yo. Sorry, you can't chat with the guide lol. Please write your own entry.")
                                            .font(.system(size: 14))
                                            .foregroundColor(popoverTextColor)
                                            .frame(width: 250)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                    } else if text.count < 350 {
                                        Text("Please free write for at minimum 5 minutes first. Then click this. Trust.")
                                            .font(.system(size: 14))
                                            .foregroundColor(popoverTextColor)
                                            .frame(width: 250)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                    } else {
                                        Button(action: {
                                            showingChatMenu = false
                                            openChatGPT()
                                        }) {
                                            Text("ChatGPT")
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(popoverTextColor)
                                        .onHover { hovering in
                                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                        }
                                        
                                        Divider()
                                        
                                        Button(action: {
                                            showingChatMenu = false
                                            openClaude()
                                        }) {
                                            Text("Claude")
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(popoverTextColor)
                                        .onHover { hovering in
                                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                        }
                                        
                                        Divider()
                                        
                                        Button(action: {
                                            copyPromptToClipboard()
                                            didCopyPrompt = true
                                        }) {
                                            Text(didCopyPrompt ? "Copied!" : "Copy Prompt")
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(popoverTextColor)
                                        .onHover { hovering in
                                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                        }
                                    }
                                }
                                .frame(minWidth: 120, maxWidth: 250)
                                .background(popoverBackgroundColor)
                                .cornerRadius(8)
                                .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
                                .onChange(of: showingChatMenu) { newValue in
                                    if !newValue {
                                        didCopyPrompt = false
                                    }
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)

                            // Backspace toggle button
                            Button(action: {
                                backspaceDisabled.toggle()
                            }) {
                                Text(backspaceDisabled ? "Backspace is Off" : "Backspace is On")
                                    .foregroundColor(isHoveringBackspaceToggle ? textHoverColor : textColor)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                isHoveringBackspaceToggle = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }

                            Text("•")
                                .foregroundColor(.gray)

                            Button(isFullscreen ? "Minimize" : "Fullscreen") {
                                if let window = NSApplication.shared.windows.first {
                                    window.toggleFullScreen(nil)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(isHoveringFullscreen ? textHoverColor : textColor)
                            .onHover { hovering in
                                isHoveringFullscreen = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Button(action: {
                                createNewEntry()
                            }) {
                                Text("New Entry")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(isHoveringNewEntry ? textHoverColor : textColor)
                            .onHover { hovering in
                                isHoveringNewEntry = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                            
                            // Theme toggle button
                            Button(action: {
                                colorScheme = colorScheme == .light ? .dark : .light
                                UserDefaults.standard.set(colorScheme == .light ? "light" : "dark", forKey: "colorScheme")
                            }) {
                                Image(systemName: colorScheme == .light ? "moon.fill" : "sun.max.fill")
                                    .foregroundColor(isHoveringThemeToggle ? textHoverColor : textColor)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                isHoveringThemeToggle = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }

                            Text("•")
                                .foregroundColor(.gray)

                            // Version history button
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showingSidebar.toggle()
                                }
                            }) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(isHoveringClock ? textHoverColor : textColor)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                isHoveringClock = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        }
                        .padding(8)
                        .cornerRadius(6)
                        .onHover { hovering in
                            isHoveringBottomNav = hovering
                        }
                    }
                    .padding()
                    .background(Color(colorScheme == .light ? .white : .black))
                    .opacity(bottomNavOpacity)
                    .onHover { hovering in
                        isHoveringBottomNav = hovering
                        if hovering {
                            withAnimation(.easeOut(duration: 0.2)) {
                                bottomNavOpacity = 1.0
                            }
                        } else if timerIsRunning {
                            withAnimation(.easeIn(duration: 1.0)) {
                                bottomNavOpacity = 0.0
                            }
                        }
                    }
                }
            }
            
            // Right sidebar
            if showingSidebar {
                Divider()
                
                VStack(spacing: 0) {
                    // Header with folder selection
                    HStack {
                        Button(action: {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: getDocumentsDirectory().path)
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Text("History")
                                            .font(.system(size: 13))
                                            .foregroundColor(isHoveringHistory ? textHoverColor : textColor)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 10))
                                            .foregroundColor(isHoveringHistory ? textHoverColor : textColor)
                                    }
                                    Text(getDocumentsDirectory().path)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isHoveringHistory = hovering
                        }
                        
                        // Folder picker button
                        Button(action: {
                            if !customDirectoryPath.isEmpty {
                                resetToDefaultDirectory()
                            } else {
                                selectCustomDirectory()
                            }
                        }) {
                            Image(systemName: !customDirectoryPath.isEmpty ? "folder.badge.minus" : "folder.badge.plus")
                                .font(.system(size: 12))
                                .foregroundColor(isHoveringFolderButton ? textHoverColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(!customDirectoryPath.isEmpty ? "Reset to default location" : "Choose custom folder location")
                        .onHover { hovering in
                            isHoveringFolderButton = hovering
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    Divider()
                    
                    // Entries List
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                Button(action: {
                                    if selectedEntryId != entry.id {
                                        if let currentId = selectedEntryId,
                                           let currentEntry = entries.first(where: { $0.id == currentId }) {
                                            saveEntry(entry: currentEntry)
                                        }
                                        
                                        selectedEntryId = entry.id
                                        loadEntry(entry: entry)
                                    }
                                }) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(entry.previewText)
                                                    .font(.system(size: 13))
                                                    .lineLimit(1)
                                                    .foregroundColor(.primary)
                                                
                                                Spacer()
                                                
                                                if hoveredEntryId == entry.id {
                                                    HStack(spacing: 8) {
                                                        Button(action: {
                                                            exportEntryAsPDF(entry: entry)
                                                        }) {
                                                            Image(systemName: "arrow.down.circle")
                                                                .font(.system(size: 11))
                                                                .foregroundColor(hoveredExportId == entry.id ?
                                                                    (colorScheme == .light ? .black : .white) :
                                                                    (colorScheme == .light ? .gray : .gray.opacity(0.8)))
                                                        }
                                                        .buttonStyle(.plain)
                                                        .help("Export entry as PDF")
                                                        .onHover { hovering in
                                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                                hoveredExportId = hovering ? entry.id : nil
                                                            }
                                                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                                        }
                                                        
                                                        Button(action: {
                                                            deleteEntry(entry: entry)
                                                        }) {
                                                            Image(systemName: "trash")
                                                                .font(.system(size: 11))
                                                                .foregroundColor(hoveredTrashId == entry.id ? .red : .gray)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .onHover { hovering in
                                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                                hoveredTrashId = hovering ? entry.id : nil
                                                            }
                                                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                                        }
                                                    }
                                                }
                                            }
                                            
                                            Text(entry.displayDate)
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(backgroundColor(for: entry))
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        hoveredEntryId = hovering ? entry.id : nil
                                    }
                                }
                                .onAppear {
                                    NSCursor.pop()
                                }
                                .help("Click to select this entry")
                                
                                if entry.id != entries.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
                .frame(width: 200)
                .background(Color(colorScheme == .light ? .white : NSColor.black))
            }
        }
        .frame(minWidth: 1100, minHeight: 600)
        .animation(.easeInOut(duration: 0.2), value: showingSidebar)
        .preferredColorScheme(colorScheme)
        .onAppear {
            showingSidebar = false
            loadExistingEntries()
        }
        .onChange(of: text) { _ in
            if let currentId = selectedEntryId,
               let currentEntry = entries.first(where: { $0.id == currentId }) {
                saveEntry(entry: currentEntry)
            }
        }
        .onReceive(timer) { _ in
            if timerIsRunning && timeRemaining > 0 {
                timeRemaining -= 1
            } else if timeRemaining == 0 {
                timerIsRunning = false
                if !isHoveringBottomNav {
                    withAnimation(.easeOut(duration: 1.0)) {
                        bottomNavOpacity = 1.0
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
    }
    
    private func backgroundColor(for entry: HumanEntry) -> Color {
        if entry.id == selectedEntryId {
            return Color.gray.opacity(0.1)
        } else if entry.id == hoveredEntryId {
            return Color.gray.opacity(0.05)
        } else {
            return Color.clear
        }
    }
    
    private func updatePreviewText(for entry: HumanEntry) {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let preview = content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = preview.isEmpty ? "" : (preview.count > 30 ? String(preview.prefix(30)) + "..." : preview)
            
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].previewText = truncated
            }
        } catch {
            print("Error updating preview text: \(error)")
        }
    }
    
    private func saveEntry(entry: HumanEntry) {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            updatePreviewText(for: entry)
        } catch {
            print("Error saving entry: \(error)")
        }
    }
    
    private func loadEntry(entry: HumanEntry) {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                text = try String(contentsOf: fileURL, encoding: .utf8)
            }
        } catch {
            print("Error loading entry: \(error)")
        }
    }
    
    private func createNewEntry() {
        let newEntry = HumanEntry.createNew(in: documentsDirectory)
        entries.insert(newEntry, at: 0)
        selectedEntryId = newEntry.id
        
        if entries.count == 1 {
            if let defaultMessageURL = Bundle.main.url(forResource: "default", withExtension: "md"),
               let defaultMessage = try? String(contentsOf: defaultMessageURL, encoding: .utf8) {
                text = defaultMessage
            }
            saveEntry(entry: newEntry)
            updatePreviewText(for: newEntry)
        } else {
            text = ""
            placeholderText = placeholderText_default
            saveEntry(entry: newEntry)
        }
    }
    
    private func openChatGPT() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullText = aiChatPrompt + "\n\n" + trimmedText
        
        if let encodedText = fullText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://chat.openai.com/?prompt=" + encodedText) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openClaude() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullText = claudePrompt + "\n\n" + trimmedText
        
        if let encodedText = fullText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://claude.ai/new?q=" + encodedText) {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyPromptToClipboard() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullText = aiChatPrompt + "\n\n" + trimmedText

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullText, forType: .string)
    }
    
    private func deleteEntry(entry: HumanEntry) {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            try fileManager.removeItem(at: fileURL)
            
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries.remove(at: index)
                
                if selectedEntryId == entry.id {
                    if let firstEntry = entries.first {
                        selectedEntryId = firstEntry.id
                        loadEntry(entry: firstEntry)
                    } else {
                        createNewEntry()
                    }
                }
            }
        } catch {
            print("Error deleting file: \(error)")
        }
    }
    
    private func extractTitleFromContent(_ content: String, date: String) -> String {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedContent.isEmpty {
            return "Entry \(date)"
        }
        
        let words = trimmedContent
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { word in
                word.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}<>"))
                    .lowercased()
            }
            .filter { !$0.isEmpty }
        
        if words.count >= 4 {
            return "\(words[0])-\(words[1])-\(words[2])-\(words[3])"
        }
        
        if !words.isEmpty {
            return words.joined(separator: "-")
        }
        
        return "Entry \(date)"
    }
    
    private func exportEntryAsPDF(entry: HumanEntry) {
        if selectedEntryId == entry.id {
            saveEntry(entry: entry)
        }
        
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            let entryContent = try String(contentsOf: fileURL, encoding: .utf8)
            let suggestedFilename = extractTitleFromContent(entryContent, date: entry.displayDate) + ".pdf"
            
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType.pdf]
            savePanel.nameFieldStringValue = suggestedFilename
            savePanel.isExtensionHidden = false
            
            if savePanel.runModal() == .OK, let url = savePanel.url {
                if let pdfData = createPDFFromText(text: entryContent) {
                    try pdfData.write(to: url)
                }
            }
        } catch {
            print("Error in PDF export: \(error)")
        }
    }
    
    private func createPDFFromText(text: String) -> Data? {
        let pageWidth: CGFloat = 612.0
        let pageHeight: CGFloat = 792.0
        let margin: CGFloat = 72.0
        
        let contentRect = CGRect(
            x: margin,
            y: margin,
            width: pageWidth - (margin * 2),
            height: pageHeight - (margin * 2)
        )
        
        let pdfData = NSMutableData()
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineHeight
        
        let font = NSFont(name: selectedFont, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ]
        
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributedString = NSAttributedString(string: trimmedText, attributes: textAttributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        
        guard let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfData as CFMutableData)!, mediaBox: nil, nil) else {
            return nil
        }
        
        var currentRange = CFRange(location: 0, length: 0)
        var pageIndex = 0
        
        let framePath = CGMutablePath()
        framePath.addRect(contentRect)
        
        while currentRange.location < attributedString.length {
            pdfContext.beginPage(mediaBox: nil)
            pdfContext.setFillColor(NSColor.white.cgColor)
            pdfContext.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
            
            let frame = CTFramesetterCreateFrame(framesetter, currentRange, framePath, nil)
            CTFrameDraw(frame, pdfContext)
            
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            currentRange.location += visibleRange.length
            
            pdfContext.endPage()
            pageIndex += 1
            
            if pageIndex > 1000 { break }
        }
        
        pdfContext.closePDF()
        return pdfData as Data
    }
}

// Helper function to calculate line height
func getLineHeight(font: NSFont) -> CGFloat {
    return font.ascender - font.descender + font.leading
}

extension NSView {
    func findTextView() -> NSView? {
        if self is NSTextView {
            return self
        }
        for subview in subviews {
            if let textView = subview.findTextView() {
                return textView
            }
        }
        return nil
    }
}

extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let typedSelf = self as? T {
            return typedSelf
        }
        for subview in subviews {
            if let found = subview.findSubview(ofType: type) {
                return found
            }
        }
        return nil
    }
}

#Preview {
    ContentView()
}
