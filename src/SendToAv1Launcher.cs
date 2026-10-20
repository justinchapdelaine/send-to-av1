// SPDX-License-Identifier: GPL-3.0-or-later
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

// Compiled as a Windows application so Explorer never allocates a console.
public static class SendToAv1Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "MessageBoxW")]
    private static extern int MessageBox(IntPtr owner, string text, string caption, uint type);

    // Quote for the native Windows argv parser, including trailing backslashes.
    public static string QuoteArgument(string value)
    {
        StringBuilder quoted = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashes++; continue; }
            quoted.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
            quoted.Append(character);
            slashes = 0;
        }
        quoted.Append('\\', slashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    public static ProcessStartInfo CreateStartInfo(string host, string gui, string mode, string[] files)
    {
        List<string> arguments = new List<string>(new string[] {
            "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", gui
        });
        if (mode == "small") { arguments.Add("-Small"); }
        else if (mode == "nvidia") { arguments.Add("-Encoder"); arguments.Add("nvenc"); }
        else if (mode != "cpu") { throw new ArgumentException("Unknown encoding mode."); }
        arguments.AddRange(files);
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = host;
        start.Arguments = String.Join(" ", arguments.ConvertAll(QuoteArgument).ToArray());
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WorkingDirectory = Path.GetDirectoryName(gui);
        return start;
    }

    private static string FindPowerShell7()
    {
        // Resolve the PATH entry at launch, retaining stable Store aliases rather
        // than pinning a versioned WindowsApps process path into the shortcut.
        foreach (string entry in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            if (String.IsNullOrWhiteSpace(entry)) { continue; }
            try
            {
                string candidate = Path.Combine(Environment.ExpandEnvironmentVariables(entry.Trim().Trim('"')), "pwsh.exe");
                if (File.Exists(candidate)) { return candidate; }
            }
            catch (ArgumentException) { }
            catch (IOException) { }
        }
        return null;
    }

    private static void Start(string host, string gui, string mode, string[] files)
    {
        using (Process process = Process.Start(CreateStartInfo(host, gui, mode, files)))
        {
            if (process == null) { throw new InvalidOperationException("PowerShell could not be started."); }
        }
    }

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length < 5 || args[0] != "--gui" || args[2] != "--mode")
            {
                throw new ArgumentException("Select videos in Explorer and use a Send to AV1 entry.");
            }
            string gui = Path.GetFullPath(args[1]);
            if (!File.Exists(gui)) { throw new FileNotFoundException("The progress-window script was not found. Run Install-SendTo.cmd again.", gui); }
            string[] files = new string[args.Length - 4];
            Array.Copy(args, 4, files, 0, files.Length);
            string preferred = FindPowerShell7();
            if (preferred != null)
            {
                try { Start(preferred, gui, args[3], files); return 0; }
                catch (Win32Exception) { /* Try the built-in Windows host below. */ }
            }
            string fallback = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            Start(fallback, gui, args[3], files);
            return 0;
        }
        catch (Exception error)
        {
            MessageBox(IntPtr.Zero, error.Message, "Send to AV1", 0x10);
            return 1;
        }
    }
}
