const std = @import("std");
const types = @import("types.zig");
const CategoryTag = types.CategoryTag;
const ProtectionClass = types.ProtectionClass;

pub fn classifyProtection(path: []const u8) ProtectionClass {
    if (std.mem.startsWith(u8, path, "/System") or
        std.mem.startsWith(u8, path, "/usr") or
        std.mem.startsWith(u8, path, "/bin") or
        std.mem.startsWith(u8, path, "/sbin") or
        std.mem.startsWith(u8, path, "/private") or
        std.mem.startsWith(u8, path, "/Library/Preferences") or
        std.mem.startsWith(u8, path, "/Library/Keychains"))
    {
        return .SystemOS;
    }

    if (std.mem.indexOf(u8, path, "/.git") != null or std.mem.endsWith(u8, path, "/.git")) {
        return .GitRepository;
    }

    if (std.mem.indexOf(u8, path, "/.ssh") != null or
        std.mem.indexOf(u8, path, "/.gnupg") != null or
        std.mem.indexOf(u8, path, "/.aws") != null or
        std.mem.indexOf(u8, path, "/.config") != null)
    {
        return .CriticalConfig;
    }

    if (std.mem.indexOf(u8, path, "/src/") != null or
        std.mem.indexOf(u8, path, "/Sources/") != null or
        std.mem.indexOf(u8, path, "/tests/") != null or
        std.mem.indexOf(u8, path, "/Tests/") != null or
        std.mem.indexOf(u8, path, "/docs/") != null)
    {
        return .ProjectSource;
    }

    return .None;
}

pub fn classifyCategory(path: []const u8, is_dir: bool) CategoryTag {
    if (is_dir) {
        if (std.mem.indexOf(u8, path, "node_modules") != null or
            std.mem.indexOf(u8, path, "target/debug") != null or
            std.mem.indexOf(u8, path, "target/release") != null or
            std.mem.indexOf(u8, path, ".zig-cache") != null or
            std.mem.indexOf(u8, path, "zig-out") != null or
            std.mem.indexOf(u8, path, "DerivedData") != null or
            std.mem.indexOf(u8, path, ".build") != null or
            std.mem.indexOf(u8, path, "build/intermediates") != null or
            std.mem.indexOf(u8, path, "Pods") != null or
            std.mem.indexOf(u8, path, "__pycache__") != null or
            std.mem.indexOf(u8, path, ".venv") != null)
        {
            return .Build_Artifacts;
        }

        if (std.mem.indexOf(u8, path, "Caches") != null or
            std.mem.indexOf(u8, path, ".cache") != null or
            std.mem.indexOf(u8, path, "Logs") != null or
            std.mem.indexOf(u8, path, "tmp") != null)
        {
            return .Caches_Logs;
        }

        if (std.mem.endsWith(u8, path, ".app") or
            std.mem.endsWith(u8, path, ".framework") or
            std.mem.endsWith(u8, path, ".plugin"))
        {
            return .Apps_Binaries;
        }

        if (std.mem.indexOf(u8, path, ".git") != null or
            std.mem.indexOf(u8, path, "src") != null)
        {
            return .Code_Dev;
        }

        return .Other;
    }

    const ext = std.fs.path.extension(path);
    if (ext.len <= 1) return .Other;
    const clean_ext = ext[1..];

    if (eqlAny(clean_ext, &.{ "app", "exe", "dylib", "so", "dll", "bin", "o", "a", "wasm" })) {
        return .Apps_Binaries;
    }

    if (eqlAny(clean_ext, &.{ "zig", "rs", "c", "cpp", "h", "hpp", "m", "mm", "swift", "go", "py", "js", "ts", "jsx", "tsx", "java", "kt", "scala", "rb", "php", "lua", "sh", "zsh", "bash", "json", "toml", "yaml", "yml", "xml", "html", "css", "sql" })) {
        return .Code_Dev;
    }

    if (eqlAny(clean_ext, &.{ "o", "obj", "class", "pyc", "pyo", "lock", "d", "rlib", "node" })) {
        return .Build_Artifacts;
    }

    if (eqlAny(clean_ext, &.{ "mp4", "mkv", "mov", "avi", "webm", "flv", "wmv", "m4v", "mpeg", "mpg", "3gp" })) {
        return .Media_Video;
    }

    if (eqlAny(clean_ext, &.{ "mp3", "wav", "flac", "aac", "ogg", "m4a", "aiff", "wma", "opus", "mid", "midi" })) {
        return .Media_Audio;
    }

    if (eqlAny(clean_ext, &.{ "png", "jpg", "jpeg", "webp", "gif", "svg", "bmp", "tiff", "tif", "heic", "raw", "psd", "ai", "ico", "icns" })) {
        return .Media_Images;
    }

    if (eqlAny(clean_ext, &.{ "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "zst", "tgz", "dmg", "iso", "pkg" })) {
        return .Archives;
    }

    if (eqlAny(clean_ext, &.{ "log", "cache", "tmp", "temp", "dmp", "crash", "asl", "out" })) {
        return .Caches_Logs;
    }

    if (eqlAny(clean_ext, &.{ "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "tsv", "pages", "numbers", "key", "epub", "mobi" })) {
        return .Documents;
    }

    if (eqlAny(clean_ext, &.{ "vmdk", "vdi", "qcow2", "raw", "img", "docker", "ova", "ovf" })) {
        return .Virtualization_VM;
    }

    return .Other;
}

fn eqlAny(ext: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(ext, item)) return true;
    }
    return false;
}
