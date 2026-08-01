namespace CodexOneClickInstaller;

internal static class TestDirectoryCleanup
{
    public static void DeleteWithoutFollowingReparsePoints(string root)
    {
        if (!Directory.Exists(root))
            return;

        foreach (var entry in Directory.EnumerateFileSystemEntries(root))
        {
            var attributes = File.GetAttributes(entry);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                if ((attributes & FileAttributes.Directory) != 0)
                    Directory.Delete(entry, recursive: false);
                else
                    File.Delete(entry);
                continue;
            }

            if ((attributes & FileAttributes.Directory) != 0)
                DeleteWithoutFollowingReparsePoints(entry);
            else
                File.Delete(entry);
        }

        Directory.Delete(root, recursive: false);
    }
}
