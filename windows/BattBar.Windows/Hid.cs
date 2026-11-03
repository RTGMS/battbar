using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace BattBar;

/// <summary>A HID collection as the OS enumerated it.</summary>
internal sealed record HidDevice(
    string Path,
    ushort VendorId,
    ushort ProductId,
    string? Product,
    string? SerialNumber,
    int? Interface,
    int? UsagePage,
    int? Usage,
    int? InputReportByteLength,
    int? OutputReportByteLength,
    int? FeatureReportByteLength);

/// <summary>Outcome of one Win32 I/O call.</summary>
/// <param name="Ok">False when the call failed; <see cref="Error"/> says why.</param>
/// <param name="Bytes">Bytes transferred.</param>
/// <param name="Error">Win32 error code, 0 when the call was cancelled by timeout.</param>
internal readonly record struct IoResult(bool Ok, int Bytes, int Error)
{
    /// <summary>The request timed out and was cancelled; no bytes moved.</summary>
    internal static IoResult Timeout() => new(true, 0, 0);

    internal static IoResult Success(int bytes) => new(true, bytes, 0);

    internal static IoResult Failure(int error) => new(false, 0, error);
}

/// <summary>
/// Win32 HID transport: SetupAPI for enumeration, <c>hid.dll</c> for reports.
/// Pure OS plumbing — no protocol knowledge lives here.
/// </summary>
internal static class Hid
{
    private const uint DIGCF_PRESENT = 0x02;
    private const uint DIGCF_DEVICEINTERFACE = 0x10;
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x01;
    private const uint FILE_SHARE_WRITE = 0x02;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x80;
    private const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    private const int ERROR_IO_PENDING = 997;
    private const int ERROR_OPERATION_ABORTED = 995;
    private const int ERROR_INVALID_HANDLE = 6;
    private const uint WAIT_OBJECT_0 = 0;
    /// <summary>How long an output report may take before it is cancelled.</summary>
    private const int WriteTimeoutMs = 1000;

    [StructLayout(LayoutKind.Sequential)]
    private struct SpDeviceInterfaceData
    {
        public uint Size;
        public Guid InterfaceClassGuid;
        public uint Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HiddAttributes
    {
        public uint Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HidpCaps
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;

        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    /// <summary>`OVERLAPPED` for I/O on a handle opened with `FILE_FLAG_OVERLAPPED`.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct Overlapped
    {
        public IntPtr Internal;
        public IntPtr InternalHigh;
        public uint Offset;
        public uint OffsetHigh;
        public IntPtr Event;
    }

    [DllImport("hid.dll")]
    private static extern void HidD_GetHidGuid(out Guid guid);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetAttributes(SafeFileHandle device, ref HiddAttributes attributes);

    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    private static extern bool HidD_GetProductString(SafeFileHandle device, [Out] char[] buffer, uint length);

    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    private static extern bool HidD_GetSerialNumberString(SafeFileHandle device, [Out] char[] buffer, uint length);

    [DllImport("hid.dll")]
    private static extern bool HidD_GetPreparsedData(SafeFileHandle device, out IntPtr data);

    [DllImport("hid.dll")]
    private static extern bool HidD_FreePreparsedData(IntPtr data);

    [DllImport("hid.dll")]
    private static extern int HidP_GetCaps(IntPtr data, ref HidpCaps caps);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_SetFeature(SafeFileHandle device, byte[] buffer, uint length);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetFeature(SafeFileHandle device, byte[] buffer, uint length);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid guid, IntPtr enumerator, IntPtr parent, uint flags);

    [DllImport("setupapi.dll")]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr deviceInfo,
        ref Guid guid, uint index, ref SpDeviceInterfaceData data);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SpDeviceInterfaceData data,
        IntPtr detail, uint detailSize, out uint required, IntPtr deviceInfo);

    [DllImport("setupapi.dll")]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(SafeFileHandle file, IntPtr buffer, uint toRead,
        out uint read, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(SafeFileHandle file, IntPtr buffer, uint toWrite,
        out uint written, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetOverlappedResult(SafeFileHandle file, IntPtr overlapped,
        out uint transferred, bool wait);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateEvent(IntPtr security, bool manualReset, bool initialState, IntPtr name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CancelIoEx(SafeFileHandle file, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    /// <summary>Enumerate every HID collection.</summary>
    internal static List<HidDevice> Enumerate()
    {
        var devices = new List<HidDevice>();
        HidD_GetHidGuid(out Guid guid);
        IntPtr set = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == IntPtr.Zero || set == new IntPtr(-1))
        {
            return devices;
        }

        try
        {
            for (uint index = 0; ; index++)
            {
                var interfaceData = new SpDeviceInterfaceData
                {
                    Size = (uint)Marshal.SizeOf<SpDeviceInterfaceData>(),
                };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, index, ref interfaceData))
                {
                    break;
                }

                if (!SetupDiGetDeviceInterfaceDetail(set, ref interfaceData, IntPtr.Zero, 0,
                        out uint required, IntPtr.Zero) && required == 0)
                {
                    continue;
                }

                IntPtr buffer = Marshal.AllocHGlobal((int)required);
                try
                {
                    // cbSize is 8 on 64-bit, 6 on 32-bit: the first field only.
                    Marshal.WriteInt32(buffer, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref interfaceData, buffer, required,
                            out _, IntPtr.Zero))
                    {
                        continue;
                    }

                    string path = Marshal.PtrToStringUni(buffer + 4) ?? string.Empty;
                    if (Describe(path) is { } device)
                    {
                        devices.Add(device);
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(set);
        }

        return devices;
    }

    private static HidDevice? Describe(string path)
    {
        using SafeFileHandle handle = OpenForQuery(path);
        if (handle.IsInvalid)
        {
            return null;
        }

        var attributes = new HiddAttributes { Size = (uint)Marshal.SizeOf<HiddAttributes>() };
        if (!HidD_GetAttributes(handle, ref attributes))
        {
            return null;
        }

        var product = new char[256];
        string? productName = HidD_GetProductString(handle, product, (uint)(product.Length * 2))
            ? Trim(product)
            : null;

        var serial = new char[256];
        string? serialNumber = HidD_GetSerialNumberString(handle, serial, (uint)(serial.Length * 2))
            ? Trim(serial)
            : null;

        int? usagePage = null;
        int? usage = null;
        int? inputLength = null;
        int? outputLength = null;
        int? featureLength = null;
        if (HidD_GetPreparsedData(handle, out IntPtr preparsed) && preparsed != IntPtr.Zero)
        {
            try
            {
                var caps = new HidpCaps();
                if (HidP_GetCaps(preparsed, ref caps) >= 0)
                {
                    usagePage = caps.UsagePage;
                    usage = caps.Usage;
                    inputLength = caps.InputReportByteLength;
                    outputLength = caps.OutputReportByteLength;
                    featureLength = caps.FeatureReportByteLength;
                }
            }
            finally
            {
                HidD_FreePreparsedData(preparsed);
            }
        }

        return new HidDevice(path, attributes.VendorID, attributes.ProductID, productName,
            serialNumber, InterfaceFromPath(path), usagePage, usage, inputLength, outputLength,
            featureLength);
    }

    private static string? Trim(char[] buffer)
    {
        int end = Array.IndexOf(buffer, '\0');
        string value = new string(buffer, 0, end < 0 ? buffer.Length : end).Trim();
        return value.Length == 0 ? null : value;
    }

    /// <summary>`\\?\hid#vid_373b&amp;pid_101a&amp;mi_01#...` → 1</summary>
    private static int? InterfaceFromPath(string path)
    {
        int marker = path.IndexOf("&mi_", StringComparison.OrdinalIgnoreCase);
        if (marker < 0)
        {
            return null;
        }

        int start = marker + 4;
        int length = 0;
        while (start + length < path.Length && Uri.IsHexDigit(path[start + length]))
        {
            length++;
        }

        return length == 0
            ? null
            : Convert.ToInt32(path.Substring(start, length), 16);
    }

    /// <summary>
    /// Open for I/O: read and write access, so output and feature reports work.
    /// </summary>
    internal static SafeFileHandle Open(string path) =>
        CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);

    /// <summary>
    /// Open just to describe a collection.
    ///
    /// Razer Synapse (and other vendor software) keeps the mouse and keyboard
    /// collections open, which makes the read/write open fail with
    /// `ERROR_ACCESS_DENIED`. Those collections were dropped from the list
    /// entirely, and the one collection that answers the battery command is the
    /// mouse collection — so the app found no Razer device at all. A zero-access
    /// open is enough for `HidD_*` queries, the same fallback hidapi uses.
    /// </summary>
    private static SafeFileHandle OpenForQuery(string path) => OpenForFeature(path, out _);

    /// <summary>
    /// Open for feature reports.
    ///
    /// Write access is preferred, but a vendor driver may hold the collection;
    /// `HidD_SetFeature` / `HidD_GetFeature` also work on a zero-access handle,
    /// which is the same fallback hidapi relies on (a Viper V2 Pro receiver on
    /// Windows is only openable with zero access while Razer software runs).
    /// </summary>
    internal static SafeFileHandle OpenForFeature(string path, out int error)
    {
        SafeFileHandle handle = Open(path);
        if (!handle.IsInvalid)
        {
            error = 0;
            return handle;
        }
        handle.Dispose();
        handle = CreateFile(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        error = handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        return handle;
    }

    /// <summary>
    /// Write an output report (first byte is the report id).
    ///
    /// The handle is opened for overlapped I/O, so an `OVERLAPPED` must be
    /// supplied even though the caller waits for the result — passing null
    /// makes `WriteFile` fail with `ERROR_INVALID_PARAMETER`.
    /// </summary>
    internal static IoResult Write(SafeFileHandle handle, byte[] report)
    {
        IntPtr evt = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        if (evt == IntPtr.Zero)
        {
            return IoResult.Failure(Marshal.GetLastWin32Error());
        }

        IntPtr overlapped = IntPtr.Zero;
        GCHandle pinned = default;
        try
        {
            overlapped = AllocateOverlapped(evt);
            pinned = GCHandle.Alloc(report, GCHandleType.Pinned);
            if (WriteFile(handle, pinned.AddrOfPinnedObject(), (uint)report.Length, out uint written,
                    overlapped))
            {
                return IoResult.Success((int)written);
            }

            int error = Marshal.GetLastWin32Error();
            if (error != ERROR_IO_PENDING)
            {
                return IoResult.Failure(error);
            }

            if (WaitForSingleObject(evt, WriteTimeoutMs) != WAIT_OBJECT_0)
            {
                return FinishCancelled(handle, overlapped);
            }
            if (!GetOverlappedResult(handle, overlapped, out written, wait: true))
            {
                return IoResult.Failure(Marshal.GetLastWin32Error());
            }
            return IoResult.Success((int)written);
        }
        finally
        {
            // The IRP has completed (or was never issued): safe to release.
            if (pinned.IsAllocated)
            {
                pinned.Free();
            }
            if (overlapped != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(overlapped);
            }
            CloseHandle(evt);
        }
    }

    /// <summary>
    /// Read one input report, waiting at most <paramref name="timeoutMs"/>.
    ///
    /// The buffer is pinned and the `OVERLAPPED` is allocated on the native heap
    /// so neither moves while the driver still owns the IRP; on timeout the IRP
    /// is cancelled and reaped before anything is released.
    /// </summary>
    internal static IoResult Read(SafeFileHandle handle, byte[] buffer, int timeoutMs)
    {
        IntPtr evt = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        if (evt == IntPtr.Zero)
        {
            return IoResult.Failure(Marshal.GetLastWin32Error());
        }

        IntPtr overlapped = IntPtr.Zero;
        GCHandle pinned = default;
        try
        {
            overlapped = AllocateOverlapped(evt);
            pinned = GCHandle.Alloc(buffer, GCHandleType.Pinned);
            if (!ReadFile(handle, pinned.AddrOfPinnedObject(), (uint)buffer.Length, out uint read,
                    overlapped))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != ERROR_IO_PENDING)
                {
                    return IoResult.Failure(error);
                }

                if (WaitForSingleObject(evt, (uint)timeoutMs) != WAIT_OBJECT_0)
                {
                    return FinishCancelled(handle, overlapped);
                }
                if (!GetOverlappedResult(handle, overlapped, out read, wait: true))
                {
                    return IoResult.Failure(Marshal.GetLastWin32Error());
                }
            }
            return IoResult.Success((int)read);
        }
        finally
        {
            if (pinned.IsAllocated)
            {
                pinned.Free();
            }
            if (overlapped != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(overlapped);
            }
            CloseHandle(evt);
        }
    }

    /// <summary>
    /// Cancel an overdue IRP and wait for it to complete, so the driver stops
    /// writing into the caller's buffer before it is unpinned.
    /// </summary>
    private static IoResult FinishCancelled(SafeFileHandle handle, IntPtr overlapped)
    {
        CancelIoEx(handle, overlapped);
        if (GetOverlappedResult(handle, overlapped, out uint transferred, wait: true))
        {
            // The IRP may have completed with data just as the timeout hit; a
            // cancel that lost the race must not throw that report away.
            return transferred > 0 ? IoResult.Success((int)transferred) : IoResult.Timeout();
        }

        int error = Marshal.GetLastWin32Error();
        return error is ERROR_OPERATION_ABORTED or ERROR_INVALID_HANDLE
            ? IoResult.Timeout()
            : IoResult.Failure(error);
    }

    /// <summary>Zeroed native `OVERLAPPED` carrying an event handle.</summary>
    private static IntPtr AllocateOverlapped(IntPtr evt)
    {
        int size = Marshal.SizeOf<Overlapped>();
        IntPtr pointer = Marshal.AllocHGlobal(size);
        for (int offset = 0; offset < size; offset++)
        {
            Marshal.WriteByte(pointer, offset, 0);
        }
        Marshal.WriteIntPtr(pointer + (int)Marshal.OffsetOf<Overlapped>(nameof(Overlapped.Event)), evt);
        return pointer;
    }

    /// <summary>Set a feature report (first byte is the report id).</summary>
    internal static IoResult SetFeature(SafeFileHandle handle, byte[] report) =>
        HidD_SetFeature(handle, report, (uint)report.Length)
            ? IoResult.Success(report.Length)
            : IoResult.Failure(Marshal.GetLastWin32Error());

    /// <summary>Read a feature report (first byte is the report id).</summary>
    internal static IoResult GetFeature(SafeFileHandle handle, byte[] report) =>
        HidD_GetFeature(handle, report, (uint)report.Length)
            ? IoResult.Success(report.Length)
            : IoResult.Failure(Marshal.GetLastWin32Error());

    /// <summary>Human-readable Win32 error, for the issue list.</summary>
    internal static string DescribeError(int code) =>
        $"{new System.ComponentModel.Win32Exception(code).Message}（0x{code:X8}）";
}
