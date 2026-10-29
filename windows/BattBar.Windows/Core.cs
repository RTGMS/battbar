using System.Runtime.InteropServices;

namespace BattBar;

/// <summary>
/// P/Invoke surface of the Rust core (<c>core/battbar-ffi</c>, shipped as
/// <c>battbar_ffi.dll</c>).
///
/// Every rule — packet layout, battery scaling, which attributes win, whether a
/// device is a mouse, retention and ordering, alert thresholds — lives in that
/// DLL. This file only marshals.
/// </summary>
internal static class Core
{
    private const string Lib = "battbar_ffi";

    internal const int StatusOk = 1;
    internal const int StatusNotForUs = 0;

    // ---- C ABI types ----------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    internal struct Reading
    {
        public byte Battery;
        public byte Charging;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct HidInfo
    {
        public IntPtr Path;
        public ushort VendorId;
        public ushort ProductId;
        public IntPtr Product;
        public IntPtr SerialNumber;
        public int Interface;
        public int UsagePage;
        public int Usage;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DeviceSummary
    {
        public IntPtr Id;
        public IntPtr Name;
        public int Provider;
        public int Connection;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MergedRef
    {
        public byte FromPrevious;
        public int Index;
        public byte Stale;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AlertDevice
    {
        public IntPtr Id;
        public int Battery;
        public int Charging;
        public byte Stale;
    }

    // ---- Imports --------------------------------------------------------

    [DllImport(Lib)]
    internal static extern uint battbar_core_version();

    [DllImport(Lib)]
    internal static extern UIntPtr battbar_atk_request_len();

    [DllImport(Lib)]
    internal static extern int battbar_atk_request([Out] byte[] buffer, UIntPtr length);

    [DllImport(Lib)]
    internal static extern int battbar_atk_decode(byte reportId, byte[] bytes, UIntPtr length,
        out Reading reading, out byte deviceStatus);

    [DllImport(Lib)]
    internal static extern UIntPtr battbar_razer_request_len();

    [DllImport(Lib)]
    internal static extern int battbar_razer_request(byte commandClass, byte commandId,
        [Out] byte[] buffer, UIntPtr length);

    [DllImport(Lib)]
    internal static extern int battbar_razer_decode_battery(byte[] bytes, UIntPtr length,
        out Reading reading);

    [DllImport(Lib)]
    internal static extern int battbar_razer_decode_charging(byte[] bytes, UIntPtr length,
        out Reading reading);

    [DllImport(Lib)]
    internal static extern int battbar_bluetooth_battery(int count, IntPtr[] keys, IntPtr[] values);

    [DllImport(Lib)]
    internal static extern int battbar_bluetooth_charging(int count, IntPtr[] keys, IntPtr[] values);

    [DllImport(Lib)]
    internal static extern byte battbar_bluetooth_is_likely_mouse(IntPtr name, IntPtr minorType);

    [DllImport(Lib)]
    internal static extern int battbar_bluetooth_windows_id(IntPtr instanceId, IntPtr name,
        [Out] byte[] output, UIntPtr length);

    [DllImport(Lib)]
    internal static extern int battbar_atk_display_name(IntPtr product, [Out] byte[] outName,
        UIntPtr nameLength, [Out] byte[] outSubtitle, UIntPtr subtitleLength);

    [DllImport(Lib)]
    internal static extern int battbar_atk_device_id(ushort vendorId, ushort productId,
        IntPtr serialNumber, IntPtr product, [Out] byte[] output, UIntPtr length);

    [DllImport(Lib)]
    internal static extern int battbar_razer_display_name(IntPtr product, ushort productId,
        [Out] byte[] outName, UIntPtr nameLength, [Out] byte[] outSubtitle, UIntPtr subtitleLength);

    [DllImport(Lib)]
    internal static extern int battbar_razer_device_id(ushort vendorId, ushort productId,
        [Out] byte[] output, UIntPtr length);

    [DllImport(Lib)]
    internal static extern int battbar_atk_select(IntPtr devices, int count, [Out] int[] indices,
        int capacity, out int outCount);

    [DllImport(Lib)]
    internal static extern int battbar_razer_select(IntPtr devices, int count, [Out] int[] indices,
        int capacity, out int outCount);

    [DllImport(Lib)]
    internal static extern IntPtr battbar_alerts_new();

    [DllImport(Lib)]
    internal static extern void battbar_alerts_free(IntPtr manager);

    [DllImport(Lib)]
    internal static extern int battbar_retry_delay_ms(byte hasStale, byte alreadyRetried);

    [DllImport(Lib)]
    internal static extern int battbar_alerts_evaluate(IntPtr manager, IntPtr devices, int count,
        byte enabled, [Out] byte[] outKinds);

    [DllImport(Lib)]
    internal static extern int battbar_merge_scan(IntPtr fresh, int freshCount, IntPtr previous,
        int previousCount, int[] failedProviders, int failedCount, IntPtr selectedId,
        IntPtr entries, out int outCount, out int outActive);

    // ---- Helpers --------------------------------------------------------

    /// <summary>UTF-8 string on the native heap; release with <see cref="Free"/>.</summary>
    internal static IntPtr Alloc(string value) =>
        Marshal.StringToCoTaskMemUTF8(value);

    internal static void Free(IntPtr pointer)
    {
        if (pointer != IntPtr.Zero)
        {
            Marshal.FreeCoTaskMem(pointer);
        }
    }

    internal static string ReadUtf8(IntPtr pointer) =>
        pointer == IntPtr.Zero ? string.Empty : Marshal.PtrToStringUTF8(pointer) ?? string.Empty;

    /// <summary>Build the native array of <see cref="HidInfo"/> for the select calls.</summary>
    internal sealed class HidInfoArray : IDisposable
    {
        private readonly IntPtr[] _strings;
        private readonly IntPtr _buffer;
        private readonly int _count;

        internal HidInfoArray(IReadOnlyList<HidDevice> devices)
        {
            _count = devices.Count;
            _strings = new IntPtr[devices.Count * 3];
            int size = Marshal.SizeOf<HidInfo>();
            _buffer = Marshal.AllocHGlobal(size * Math.Max(1, _count));

            for (int index = 0; index < _count; index++)
            {
                HidDevice device = devices[index];
                IntPtr path = Alloc(device.Path);
                IntPtr product = Alloc(device.Product ?? string.Empty);
                IntPtr serial = Alloc(device.SerialNumber ?? string.Empty);
                _strings[index * 3] = path;
                _strings[index * 3 + 1] = product;
                _strings[index * 3 + 2] = serial;

                var info = new HidInfo
                {
                    Path = path,
                    VendorId = device.VendorId,
                    ProductId = device.ProductId,
                    Product = product,
                    SerialNumber = serial,
                    Interface = device.Interface ?? -1,
                    UsagePage = device.UsagePage ?? -1,
                    Usage = device.Usage ?? -1,
                };
                Marshal.StructureToPtr(info, _buffer + index * size, false);
            }
        }

        internal IntPtr Pointer => _buffer;

        internal int Count => _count;

        public void Dispose()
        {
            foreach (IntPtr pointer in _strings)
            {
                Free(pointer);
            }
            Marshal.FreeHGlobal(_buffer);
        }
    }
}
