import Foundation

private let ffxivConfigRelativePath = "My Games/FINAL FANTASY XIV - KOREA/FFXIV.cfg"

func findExistingFFXIVConfig(
    bottleURL: URL,
    homeURL: URL,
    fileManager: FileManager = .default
) throws -> URL? {
    let usersRoot = bottleURL.appendingPathComponent("drive_c/users", isDirectory: true)
    guard let users = try? fileManager.contentsOfDirectory(
        at: usersRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }

    let resolvedUsersRoot = usersRoot.resolvingSymlinksInPath().standardizedFileURL
    let resolvedHomeDocuments = homeURL.appendingPathComponent("Documents", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
    var matches: [URL] = []

    for user in users where user.lastPathComponent != "Public" {
        let documents = user.appendingPathComponent("Documents", isDirectory: true)
        let resolvedDocuments = documents.resolvingSymlinksInPath().standardizedFileURL
        let documentsPath = resolvedDocuments.path
        let allowedExternal = documentsPath == resolvedHomeDocuments.path
        let allowedInternal = documentsPath == resolvedUsersRoot.path ||
            documentsPath.hasPrefix(resolvedUsersRoot.path + "/")
        guard allowedExternal || allowedInternal else { continue }

        let candidate = documents.appendingPathComponent(ffxivConfigRelativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let expected = resolvedDocuments.appendingPathComponent(ffxivConfigRelativePath)
            .standardizedFileURL
        guard candidate.path == expected.path,
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }
        if !matches.contains(where: { $0.path == candidate.path }) { matches.append(candidate) }
    }

    guard matches.count <= 1 else {
        throw LauncherError.path("FFXIV.cfg가 여러 사용자 프로필에서 발견되어 안전하게 선택할 수 없습니다.")
    }
    return matches.first
}

@discardableResult
func enableOpeningMovieSkip(
    at configURL: URL,
    fileManager: FileManager = .default
) throws -> Bool {
    guard configURL.isFileURL,
          (try? configURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        throw LauncherError.path("기존 FFXIV.cfg를 찾을 수 없습니다.")
    }
    let original = try Data(contentsOf: configURL)
    guard let text = String(data: original, encoding: .utf8) else {
        throw LauncherError.path("FFXIV.cfg가 UTF-8 텍스트가 아닙니다.")
    }
    let expression = try NSRegularExpression(
        pattern: #"(?m)^([ \t]*CutsceneMovieOpening(?:[ \t]*=[ \t]*|[ \t]+))([^\r\n]*?)([ \t]*)$"#
    )
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = expression.matches(in: text, range: range)
    guard matches.count == 1, let match = matches.first,
          let prefixRange = Range(match.range(at: 1), in: text),
          let valueRange = Range(match.range(at: 2), in: text),
          let suffixRange = Range(match.range(at: 3), in: text) else {
        throw LauncherError.path("FFXIV.cfg의 CutsceneMovieOpening 항목을 안전하게 찾을 수 없습니다.")
    }
    guard text[valueRange].trimmingCharacters(in: .whitespaces) != "1" else { return false }

    let replacement = String(text[prefixRange]) + "1" + String(text[suffixRange])
    let updated = expression.stringByReplacingMatches(
        in: text,
        range: range,
        withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
    )
    guard let updatedData = updated.data(using: .utf8) else {
        throw LauncherError.path("FFXIV.cfg 변경 내용을 인코딩하지 못했습니다.")
    }

    let backup = configURL.appendingPathExtension("xivkr-backup")
    if !fileManager.fileExists(atPath: backup.path) {
        try fileManager.copyItem(at: configURL, to: backup)
    }
    try updatedData.write(to: configURL, options: [.atomic])
    return true
}
