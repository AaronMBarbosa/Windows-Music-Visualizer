using System.Runtime.InteropServices;

namespace WindowsMusicVisualizerGpu;

public sealed class WasapiLoopbackCapture : IDisposable
{
    private static readonly Guid ClientId = new("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    private static readonly Guid CaptureId = new("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
    private IAudioClient? client;
    private IAudioCaptureClient? capture;
    private IntPtr formatPointer;
    private readonly AutoResetEvent ready = new(false);
    private WaveFormat format;
    private bool floatingPoint;
    private float[] pendingLeft = [], pendingRight = [];
    private int pendingOffset, pendingCount;
    public int SampleRate => (int)format.Rate;
    public string? EndpointId { get; private set; }
    public static bool SupportsApplicationCapture => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348);

    public WasapiLoopbackCapture(AudioSource? source = null, int processId = 0)
    {
        source ??= AudioSource.SystemDefault;
        try
        {
            if (source.ProcessName != null)
            {
                if (!SupportsApplicationCapture) throw new NotSupportedException("App capture requires Windows build 20348 or newer.");
                if (processId <= 0) throw new InvalidOperationException("Waiting for the selected app.");
                client = ActivateProcess(processId);
                format = new WaveFormat { Tag = 1, Channels = 2, Rate = 48000, Average = 192000, Align = 4, Bits = 16 };
                formatPointer = Marshal.AllocCoTaskMem(Marshal.SizeOf<WaveFormat>());
                Marshal.StructureToPtr(format, formatPointer, false);
            }
            else
            {
                var enumerator = (IMMDeviceEnumerator)(object)new DeviceEnumerator();
                IMMDevice? device = null;
                try
                {
                    Check(source.DeviceId == null ? enumerator.GetDefaultAudioEndpoint(0, 1, out device) : enumerator.GetDevice(source.DeviceId, out device));
                    Check(device.GetId(out string endpointId));
                    EndpointId = endpointId;
                    var id = ClientId;
                    Check(device.Activate(ref id, 23, IntPtr.Zero, out object instance));
                    client = (IAudioClient)instance;
                    Check(client.GetMixFormat(out formatPointer));
                    format = Marshal.PtrToStructure<WaveFormat>(formatPointer);
                }
                finally { Release(device); Release(enumerator); }
            }
            floatingPoint = format.Tag == 3 || (format.Tag == 65534 && Marshal.PtrToStructure<Guid>(IntPtr.Add(formatPointer, 24)) == new Guid("00000003-0000-0010-8000-00aa00389b71"));
            if (format.Channels < 1 || format.Rate == 0 || (floatingPoint ? format.Bits != 32 : format.Bits is not (16 or 24 or 32)))
                throw new NotSupportedException("Unsupported audio sample format.");
            int flags = 0x00020000 | 0x00040000;
            if (source.ProcessName != null) flags |= unchecked((int)0x80000000);
            Check(client.Initialize(0, flags, 0, 0, formatPointer, IntPtr.Zero));
            Check(client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle()));
            var captureId = CaptureId;
            Check(client.GetService(ref captureId, out object service));
            capture = (IAudioCaptureClient)service;
            Check(client.Start());
        }
        catch { Dispose(); throw; }
    }

    public int Read(float[] left, float[] right)
    {
        int capacity = Math.Min(left.Length, right.Length), written = 0;
        while (written < capacity)
        {
            if (pendingCount > 0)
            {
                int count = Math.Min(pendingCount, capacity - written);
                Array.Copy(pendingLeft, pendingOffset, left, written, count);
                Array.Copy(pendingRight, pendingOffset, right, written, count);
                written += count; pendingOffset += count; pendingCount -= count;
                continue;
            }
            Check(capture!.GetNextPacketSize(out int packet));
            if (packet == 0) break;
            Check(capture.GetBuffer(out IntPtr data, out int frames, out int flags, out _, out _));
            try
            {
                if (pendingLeft.Length < frames) { pendingLeft = new float[frames]; pendingRight = new float[frames]; }
                for (int i = 0; i < frames; i++)
                {
                    pendingLeft[i] = (flags & 2) != 0 ? 0 : Sample(data, i, 0);
                    pendingRight[i] = (flags & 2) != 0 ? 0 : Sample(data, i, Math.Min(1, format.Channels - 1));
                    // Standard channel order: center/LFE feed both, surrounds feed their side.
                    for (int channel = 2; channel < format.Channels && (flags & 2) == 0; channel++)
                    {
                        float extra = Sample(data, i, channel) * 0.5f;
                        if (channel < 4) { pendingLeft[i] += extra; pendingRight[i] += extra; }
                        else if ((channel & 1) == 0) pendingLeft[i] += extra;
                        else pendingRight[i] += extra;
                    }
                }
                pendingOffset = 0; pendingCount = frames;
            }
            finally { Check(capture.ReleaseBuffer(frames)); }
        }
        return written;
    }

    private float Sample(IntPtr data, int frame, int channel)
    {
        int offset = frame * format.Align + channel * (format.Bits / 8);
        if (floatingPoint)
        {
            float value = BitConverter.Int32BitsToSingle(Marshal.ReadInt32(data, offset));
            return float.IsFinite(value) ? value : 0;
        }
        if (format.Bits == 16) return Marshal.ReadInt16(data, offset) / 32768f;
        if (format.Bits == 32) return Marshal.ReadInt32(data, offset) / 2147483648f;
        int sample = Marshal.ReadByte(data, offset) | Marshal.ReadByte(data, offset + 1) << 8 | Marshal.ReadByte(data, offset + 2) << 16;
        return (sample << 8 >> 8) / 8388608f;
    }

    public static List<AudioSource> Devices()
    {
        var result = new List<AudioSource>();
        var enumerator = (IMMDeviceEnumerator)(object)new DeviceEnumerator();
        IMMDeviceCollection? collection = null;
        try
        {
            Check(enumerator.EnumAudioEndpoints(0, 1, out collection));
            Check(collection.GetCount(out int count));
            for (int i = 0; i < count; i++)
            {
                Check(collection.Item(i, out var device));
                IPropertyStore? properties = null;
                try
                {
                    Check(device.GetId(out string id));
                    Check(device.OpenPropertyStore(0, out properties));
                    var key = new PropertyKey { Format = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), Id = 14 };
                    Check(properties.GetValue(ref key, out var value));
                    try { result.Add(new AudioSource("Output: " + (Marshal.PtrToStringUni(value.Pointer) ?? id), DeviceId: id)); }
                    finally { PropVariantClear(ref value); }
                }
                finally { Release(properties); Release(device); }
            }
        }
        finally { Release(collection); Release(enumerator); }
        return result;
    }

    public static string DefaultEndpointId()
    {
        var enumerator = (IMMDeviceEnumerator)(object)new DeviceEnumerator();
        IMMDevice? device = null;
        try
        {
            Check(enumerator.GetDefaultAudioEndpoint(0, 1, out device));
            Check(device.GetId(out string id));
            return id;
        }
        finally { Release(device); Release(enumerator); }
    }

    private static IAudioClient ActivateProcess(int processId)
    {
        var completion = new ActivationCompletion();
        var parameters = Marshal.AllocCoTaskMem(12);
        Marshal.WriteInt32(parameters, 0, 1);
        Marshal.WriteInt32(parameters, 4, processId);
        Marshal.WriteInt32(parameters, 8, 0);
        var variant = new PropVariant { Type = 65, Blob = new Blob { Size = 12, Data = parameters } };
        IActivationOperation? operation = null;
        bool started = false;
        try
        {
            var id = ClientId;
            Check(ActivateAudioInterfaceAsync("VAD\\Process_Loopback", ref id, ref variant, completion, out operation));
            started = true;
            if (!completion.Result.Task.Wait(TimeSpan.FromSeconds(10)))
            {
                _ = completion.Result.Task.ContinueWith(t => { if (t.IsCompletedSuccessfully) Release(t.Result); });
                throw new TimeoutException("Audio source activation timed out.");
            }
            return (IAudioClient)completion.Result.Task.GetAwaiter().GetResult();
        }
        finally
        {
            if (started && !completion.Result.Task.IsCompleted)
                _ = completion.Result.Task.ContinueWith(_ => { Release(operation); Marshal.FreeCoTaskMem(parameters); });
            else { Release(operation); Marshal.FreeCoTaskMem(parameters); }
            GC.KeepAlive(completion);
        }
    }

    public void Dispose()
    {
        if (client != null) { try { client.Stop(); } catch { } }
        Release(capture); capture = null;
        Release(client); client = null;
        if (formatPointer != IntPtr.Zero) { Marshal.FreeCoTaskMem(formatPointer); formatPointer = IntPtr.Zero; }
        ready.Dispose();
    }
    private static void Check(int result) => Marshal.ThrowExceptionForHR(result);
    private static void Release(object? value) { if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    private sealed class ActivationCompletion : IActivationCompletion, IAgileObject
    {
        public readonly TaskCompletionSource<object> Result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int ActivateCompleted(IActivationOperation operation)
        {
            try { Check(operation.GetActivateResult(out int hr, out object instance)); Check(hr); Result.TrySetResult(instance); }
            catch (Exception ex) { Result.TrySetException(ex); }
            return 0;
        }
    }
    [ComVisible(true), Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAgileObject { }
    [ComVisible(true), Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivationCompletion { [PreserveSig] int ActivateCompleted(IActivationOperation operation); }
    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivationOperation { [PreserveSig] int GetActivateResult(out int result, [MarshalAs(UnmanagedType.IUnknown)] out object instance); }
    [DllImport("Mmdevapi.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int ActivateAudioInterfaceAsync(string path, ref Guid iid, ref PropVariant parameters, IActivationCompletion completion, out IActivationOperation operation);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
    [StructLayout(LayoutKind.Explicit)] private struct PropVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Pointer;
        [FieldOffset(8)] public Blob Blob;
    }
    [StructLayout(LayoutKind.Sequential)] private struct PropertyKey { public Guid Format; public int Id; }
    [StructLayout(LayoutKind.Sequential, Pack = 2)] private struct WaveFormat
    {
        public ushort Tag, Channels;
        public uint Rate, Average;
        public ushort Align, Bits, Size;
    }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] private sealed class DeviceEnumerator;
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, int states, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }
    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient
    {
        [PreserveSig] int Initialize(int mode, int flags, long duration, long periodicity, IntPtr format, IntPtr session);
        [PreserveSig] int GetBufferSize(out int frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out int frames);
        [PreserveSig] int IsFormatSupported(int mode, IntPtr format, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long normal, out long minimum);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }
    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out int frames, out int flags, out long position, out long qpc);
        [PreserveSig] int ReleaseBuffer(int frames);
        [PreserveSig] int GetNextPacketSize(out int frames);
    }
}
