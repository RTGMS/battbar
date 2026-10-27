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
    int? Usage);

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
    private const uint WAIT_OBJECT_0 = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct SpDeviceInterfaceData
    {
        public uint Size;
        public Guid InterfaceClassGuid;
        public uint Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SpDeviceInfoData
    {
        public uint Size;
        public Guid ClassGuid;
        public uint DevInst;
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

    [DllImport("hid.dll")]
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

    [DllImport("hid.dll")]
    private static extern bool HidD_SetFeature(SafeFileHandle device, byte[] buffer, uint length);

    [DllImport("hid.dll")]
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
    private static extern bool ReadFile(SafeFileHandle file, byte[] buffer, uint toRead,
        out uint read, ref Overlapped overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(SafeFileHandle file, byte[] buffer, uint toWrite,
        out uint written, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateEvent(IntPtr security, bool manualReset, bool initialState, IntPtr name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CancelIoEx(SafeFileHandle file, ref Overlapped overlapped);

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
            // cli01 → 1
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
        using SafeFileHandle handle = Open(path);
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
        if (HidD_GetPreparsedData(handle, out IntPtr preparsed) && preparsed != IntPtr.Zero)
        {
            try
            {
                var caps = new HidpCaps();
                if (HidP_GetCaps(preparsed, ref caps) >= 0)
                {
                    usagePage = caps.UsagePage;
                    usage = caps.Usage;
                }
            }
            finally
            {
                HidD_FreePreparsedData(preparsed);
            }
        }

        return new HidDevice(path, attributes.VendorID, attributes.ProductID, productName,
            serialNumber, InterfaceFromPath(path), usagePage, usage);
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

    internal static SafeFileHandle Open(string path) =>
        CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);

    /// <summary>Write an output report (first byte is the report id).</summary>
    internal static bool Write(SafeFileHandle handle, byte[] report) =>
        WriteFile(handle, report, (uint)report.Length, out _, IntPtr.Zero);

    /// <summary>Read one input report, waiting at most <paramref name="timeoutMs"/>.</summary>
    internal static int Read(SafeFileHandle handle, byte[] buffer, int timeoutMs)
    {
        IntPtr evt = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        if (evt == IntPtr.Zero)
        {
            return 0;
        }

        try
        {
            var overlapped = new Overlapped { Event = evt };
            if (!ReadFile(handle, buffer, (uint)buffer.Length, out uint read, ref overlapped))
            {
                if (Marshal.GetLastWin32Error() != ERROR_IO_PENDING)
                {
                    return 0;
                }
                if (WaitForSingleObject(evt, (uint)timeoutMs) != WAIT_OBJECT_0)
                {
                    CancelIoEx(handle, ref overlapped);
                    return 0;
                }
                // Bytes actually read are stored in InternalHigh.
                read = (uint)overlapped.InternalHigh.ToInt32();
            }
            return (int)read;
        }
        finally
        {
            CloseHandle(evt);
        }
    }

    internal static bool SetFeature(SafeFileHandle handle, byte[] report) =>
        HidD_SetFeature(handle, report, (uint)report.Length);

    internal static bool GetFeature(SafeFileHandle handle, byte[] report) =>
        HidD_GetFeature(handle, report, (uint)report.Length);
}
