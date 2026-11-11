using System;
using System.Collections.Generic;
using System.Net.Http;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Loupedeck.AiAgentDeckPlugin
{
    public class AiAgentDeckApplication : ClientApplication
    {
        protected override string GetBundleName() => "";
        protected override string GetProcessName() => "";
    }

    public class AiAgentDeckPlugin : Plugin
    {
        public override bool UsesApplicationApiOnly => false;
        public override bool HasNoApplication => true;

        public override void Load()
        {
            DeckClient.EnsurePolling();
        }

        public override void Unload()
        {
            DeckClient.StopPolling();
        }
    }

    internal static class DeckClient
    {
        public static event Action StateUpdated;

        private const string OfflineSvg = @"<svg xmlns='http://www.w3.org/2000/svg' width='{{size}}' height='{{size}}' viewBox='0 0 100 100'>
  <rect width='100' height='100' rx='18' fill='#080c15'/>
  <rect x='1.5' y='1.5' width='97' height='97' rx='16.5' fill='none' stroke='#334155' stroke-width='1.6'/>
  <text x='50' y='46' text-anchor='middle' fill='#94a3b8' font-size='12' font-family='Helvetica Neue, Helvetica, Arial, sans-serif' font-weight='700'>OFFLINE</text>
  <text x='50' y='64' text-anchor='middle' fill='#64748b' font-size='8' font-family='Helvetica Neue, Helvetica, Arial, sans-serif' font-weight='700'>OPEN AGENT DECK</text>
</svg>";

        private static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(700) };
        private static readonly HttpClient ActionHttp = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        private static readonly SemaphoreSlim ActionGate = new SemaphoreSlim(1, 1);
        private static readonly Dictionary<string, long> LastPress = new Dictionary<string, long>();
        private static readonly HttpClient StreamHttp = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        private static CancellationTokenSource _streamCancellation;
        private static bool _streamConnected;
        private static readonly HashSet<string> HoldKeys = new HashSet<string>();
        private static readonly Dictionary<string, long> HoldStarts = new Dictionary<string, long>();
        private static readonly Dictionary<string, long> HoldRevisions = new Dictionary<string, long>();
        private static System.Timers.Timer _holdTimer;
        private static string _pendingState = "";
        private static string _feedback = "";
        private static long _feedbackUntil;
        private static string _feedbackCaption = "HOLD TO CONFIRM";
        private static string _serverInstanceId = "";
        private static readonly Dictionary<string, string> HoldInstances = new Dictionary<string, string>();
        private static long _revision;
        private static string _selectedSessionId = "";
        private static readonly object Gate = new object();
        private static readonly Dictionary<string, string> SvgByKey = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private static string[] _slotSvg = new string[9];
        private static string _dialSvg = "";
        private static string _signature = "";
        private static bool _online;
        private static int _busy;
        private static System.Timers.Timer _timer;

        static DeckClient()
        {
            Http.DefaultRequestHeaders.TryAddWithoutValidation("X-Agent-Deck", "1");
            ActionHttp.DefaultRequestHeaders.TryAddWithoutValidation("X-Agent-Deck", "1");
        }

        public static void EnsurePolling()
        {
            if (_timer != null) return;
            Refresh();
            _streamCancellation = new CancellationTokenSource();
            _ = StreamUpdates(_streamCancellation.Token);
            _timer = new System.Timers.Timer(2000) { AutoReset = true };
            _timer.Elapsed += (_, __) => { if (!_streamConnected) Refresh(); };
            _timer.Start();
        }

        public static void StopPolling()
        {
            _streamCancellation?.Cancel();
            _streamCancellation?.Dispose();
            _streamCancellation = null;
            if (_timer == null) return;
            _timer.Stop();
            _timer.Dispose();
            _timer = null;
        }

        public static void Refresh()
        {
            if (Interlocked.Exchange(ref _busy, 1) == 1) return;
            try
            {
                string json = null;
                try
                {
                    var connection = ReadConnection();
                    using var request = Request(HttpMethod.Get, "/status", connection);
                    using var response = Http.SendAsync(request).GetAwaiter().GetResult();
                    response.EnsureSuccessStatusCode();
                    json = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                }
                catch
                {
                    json = null;
                }

                var changed = false;
                lock (Gate)
                {
                    if (string.IsNullOrWhiteSpace(json))
                    {
                        if (_online || _signature != "offline")
                        {
                            _online = false;
                            SvgByKey.Clear();
                            _slotSvg = new string[9];
                            _dialSvg = "";
                            _signature = "offline";
                            changed = true;
                        }
                    }
                    else
                    {
                        try { changed = ApplyOrBuffer(json); }
                        catch { changed = false; }
                    }
                }
                if (changed) StateUpdated?.Invoke();
            }
            finally
            {
                Interlocked.Exchange(ref _busy, 0);
            }
        }

        private static (string Url, string Token) ReadConnection()
        {
            try
            {
                var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Caches", "AgentDeck", "connection.json");
                using var doc = JsonDocument.Parse(File.ReadAllText(path));
                return ("http://127.0.0.1:" + doc.RootElement.GetProperty("port").GetInt32(), doc.RootElement.GetProperty("token").GetString() ?? "");
            }
            catch { return ("http://127.0.0.1:19420", ""); }
        }

        private static HttpRequestMessage Request(HttpMethod method, string path, (string Url, string Token) connection)
        {
            var request = new HttpRequestMessage(method, connection.Url + path);
            request.Headers.TryAddWithoutValidation("X-Agent-Deck", "1");
            if (!string.IsNullOrEmpty(connection.Token)) request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + connection.Token);
            return request;
        }

        private static async Task StreamUpdates(CancellationToken cancellation)
        {
            while (!cancellation.IsCancellationRequested)
            {
                try
                {
                    var connection = ReadConnection();
                    if (string.IsNullOrEmpty(connection.Token)) { await Task.Delay(2000, cancellation); continue; }
                    using var request = Request(HttpMethod.Get, "/events", connection);
                    using var response = await StreamHttp.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
                    response.EnsureSuccessStatusCode();
                    using var stream = await response.Content.ReadAsStreamAsync(cancellation);
                    using var reader = new StreamReader(stream);
                    _streamConnected = true;
                    while (!cancellation.IsCancellationRequested)
                    {
                        var line = await reader.ReadLineAsync(cancellation);
                        if (line == null) break;
                        if (!line.StartsWith("data: ")) continue;
                        bool changed;
                        lock (Gate) changed = ApplyOrBuffer(line.Substring(6));
                        if (changed) StateUpdated?.Invoke();
                    }
                }
                catch (Exception err) when (!(err is OperationCanceledException)) { Console.Error.WriteLine("[Agent Deck] Reconnecting: " + err.Message); }
                finally { _streamConnected = false; }
                try { await Task.Delay(1000, cancellation); } catch (OperationCanceledException) { break; }
            }
        }

        public static bool NeedsHold(string key)
        {
            lock (Gate) return HoldKeys.Contains(key);
        }

        public static void BeginHold(string key)
        {
            lock (Gate)
            {
                if (HoldStarts.ContainsKey(key)) return;
                var started = Environment.TickCount64;
                HoldStarts[key] = started;
                HoldRevisions[key] = _revision;
                HoldInstances[key] = _serverInstanceId;
                _ = Task.Run(async () =>
                {
                    await Task.Delay(8000);
                    lock (Gate)
                    {
                        if (!HoldStarts.TryGetValue(key, out var current) || current != started) return;
                        HoldStarts.Remove(key); HoldRevisions.Remove(key); HoldInstances.Remove(key);
                        if (HoldStarts.Count == 0) { _holdTimer?.Dispose(); _holdTimer = null; FlushBufferedState(); }
                    }
                    ShowFeedback(key, "HOLD CANCELLED", 2000);
                });
                if (_holdTimer == null)
                {
                    _holdTimer = new System.Timers.Timer(60);
                    _holdTimer.Elapsed += (_, __) => StateUpdated?.Invoke();
                    _holdTimer.Start();
                }
            }
        }

        public static void EndHold(string key)
        {
            long start, revision;
            string instanceId;
            lock (Gate)
            {
                if (!HoldStarts.TryGetValue(key, out start)) return;
                revision = HoldRevisions[key];
                instanceId = HoldInstances[key];
                HoldStarts.Remove(key); HoldRevisions.Remove(key); HoldInstances.Remove(key);
                if (HoldStarts.Count == 0) { _holdTimer?.Dispose(); _holdTimer = null; FlushBufferedState(); }
            }
            var elapsed = (int)(Environment.TickCount64 - start);
            if (elapsed >= 700) Post("/press/" + Uri.EscapeDataString(key), elapsed, revision, instanceId);
            else ShowFeedback(key, "HOLD TO CONFIRM", 2000);
            StateUpdated?.Invoke();
        }

        private static bool ApplyOrBuffer(string json)
        {
            if (HoldStarts.Count > 0) { _pendingState = json; return false; }
            return Apply(json);
        }

        private static void FlushBufferedState()
        {
            if (HoldStarts.Count == 0 && !string.IsNullOrEmpty(_pendingState))
            {
                var json = _pendingState; _pendingState = "";
                Apply(json);
            }
        }

        private static bool Apply(string json)
        {
            using (var doc = JsonDocument.Parse(json))
            {
                var root = doc.RootElement;
                _serverInstanceId = root.TryGetProperty("instanceId", out var instance) ? instance.GetString() ?? "" : "";
                if (root.TryGetProperty("revision", out var revision)) _revision = revision.GetInt64();
                if (root.TryGetProperty("selectedSessionId", out var selected)) _selectedSessionId = selected.GetString() ?? "";
                HoldKeys.Clear();
                var next = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                var slots = new string[9];
                var sig = new StringBuilder();
                if (root.TryGetProperty("tiles", out var tiles) && tiles.ValueKind == JsonValueKind.Array)
                {
                    var index = 0;
                    foreach (var tile in tiles.EnumerateArray())
                    {
                        var key = tile.TryGetProperty("key", out var keyProp) ? keyProp.GetString() ?? "" : "";
                        var svg = tile.TryGetProperty("svg", out var svgProp) ? svgProp.GetString() ?? "" : "";
                        if (!string.IsNullOrEmpty(key)) next[key] = svg;
                        if (tile.TryGetProperty("requiresHold", out var hold) && hold.GetBoolean())
                        {
                            HoldKeys.Add(key);
                            HoldKeys.Add(index.ToString());
                        }
                        if (index < slots.Length) slots[index] = svg;
                        sig.Append(key).Append(':').Append(svg.Length).Append(':').Append(svg.GetHashCode()).Append('|');
                        index++;
                    }
                }
                var dial = "";
                if (root.TryGetProperty("dial", out var dialProp) && dialProp.TryGetProperty("svg", out var dialSvg))
                {
                    dial = dialSvg.GetString() ?? "";
                }
                sig.Append(dial.GetHashCode());
                var signature = sig.ToString();
                if (signature == _signature && _online) return false;
                SvgByKey.Clear();
                foreach (var pair in next) SvgByKey[pair.Key] = pair.Value;
                _slotSvg = slots;
                _dialSvg = dial;
                _signature = signature;
                _online = true;
                return true;
            }
        }

        public static BitmapImage Render(string parameter, PluginImageSize imageSize, bool dial = false)
        {
            string svg;
            lock (Gate)
            {
                svg = dial ? _dialSvg : SvgFor(parameter);
                if (string.IsNullOrEmpty(svg)) svg = OfflineSvg;
            }
            lock (Gate)
            {
                var key = parameter ?? "0";
                if (HoldStarts.TryGetValue(key, out var start))
                {
                    var progress = Math.Min(1.0, (Environment.TickCount64 - start) / 700.0);
                    var offset = (289 * (1 - progress)).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
                    svg = svg.Replace("</svg>", "<circle cx='50' cy='50' r='46' fill='none' stroke='#79BE9C' stroke-width='4' stroke-dasharray='289' stroke-dashoffset='" + offset + "' transform='rotate(-90 50 50)'/></svg>");
                }
                if (_feedback == key && Environment.TickCount64 < _feedbackUntil)
                    svg = svg.Replace("</svg>", "<rect x='5' y='74' width='90' height='21' rx='5' fill='#302719'/><text x='50' y='88' text-anchor='middle' fill='#E9AD45' font-size='8'>" + _feedbackCaption + "</text></svg>");
            }
            var sized = svg.Replace("{{size}}", PixelSize(imageSize));
            try
            {
                return BitmapImage.FromArray(Encoding.UTF8.GetBytes(sized));
            }
            catch
            {
                using (var builder = new BitmapBuilder(imageSize))
                {
                    builder.Clear(new BitmapColor(8, 12, 21));
                    return builder.ToImage();
                }
            }
        }

        private static string SvgFor(string parameter)
        {
            if (!_online) return OfflineSvg;
            var key = string.IsNullOrEmpty(parameter) ? "0" : parameter;
            if (SvgByKey.TryGetValue(key, out var svg) && !string.IsNullOrEmpty(svg)) return svg;
            if (int.TryParse(key, out var index) && index >= 0 && index < _slotSvg.Length && !string.IsNullOrEmpty(_slotSvg[index]))
            {
                return _slotSvg[index];
            }
            return OfflineSvg;
        }

        private static string PixelSize(PluginImageSize imageSize)
        {
            var name = imageSize.ToString();
            if (name.StartsWith("Width") && int.TryParse(name.Substring(5), out var named) && named > 0) return named.ToString();
            if (int.TryParse(name, out var raw) && raw > 0) return raw.ToString();
            return "80";
        }

        private static void ShowFeedback(string key, string caption, int duration)
        {
            lock (Gate) { _feedback = key; _feedbackCaption = caption; _feedbackUntil = Environment.TickCount64 + duration; }
            StateUpdated?.Invoke();
            _ = Task.Run(async () => { await Task.Delay(duration); StateUpdated?.Invoke(); });
        }

        public static void Post(string path, int heldMs = 0, long? expectedRevision = null, string expectedInstanceId = null)
        {
            long revision;
            string sessionId, instanceId;
            lock (Gate)
            {
                var now = Environment.TickCount64;
                if (LastPress.TryGetValue(path, out var previous) && now - previous < 300) return;
                LastPress[path] = now;
                revision = expectedRevision ?? _revision;
                sessionId = _selectedSessionId;
                instanceId = expectedInstanceId ?? _serverInstanceId;
            }
            _ = Task.Run(async () =>
            {
                await ActionGate.WaitAsync();
                try
                {
                    using var body = new StringContent(JsonSerializer.Serialize(new { revision, sessionId, instanceId, heldMs, commandId = Guid.NewGuid().ToString() }), Encoding.UTF8, "application/json");
                    using var request = Request(HttpMethod.Post, path, ReadConnection());
                    request.Content = body;
                    using var response = await ActionHttp.SendAsync(request);
                    var json = await response.Content.ReadAsStringAsync();
                    using var result = JsonDocument.Parse(json);
                    if (!response.IsSuccessStatusCode || !result.RootElement.TryGetProperty("ok", out var ok) || !ok.GetBoolean())
                    {
                        Console.Error.WriteLine("[AI Agent Deck] " + json);
                        if (path.StartsWith("/press/")) ShowFeedback(Uri.UnescapeDataString(path.Substring(7)), "SEE APP", 4000);
                    }
                    else if (path.StartsWith("/press/")) ShowFeedback(Uri.UnescapeDataString(path.Substring(7)), "DONE", 900);
                }
                catch (Exception err)
                {
                    Console.Error.WriteLine("[AI Agent Deck] Action failed: " + err.Message);
                    lock (Gate) { _online = false; _signature = "action-failed"; }
                    StateUpdated?.Invoke();
                }
                finally { ActionGate.Release(); Refresh(); }
            });
        }
    }

    public class AiAgentStatusCommand : PluginDynamicCommand
    {
        private static readonly (string Key, string Group)[] Items =
        {
            ("antigravity", "AI Agents"),
            ("claude", "AI Agents"),
            ("cursor", "AI Agents"),
            ("gemini", "AI Agents"),
            ("codex", "AI Agents"),
            ("summary", "AI Agents"),
            ("approve", "AI Controls"),
            ("deny", "AI Controls"),
            ("dashboard", "AI Controls"),
            ("0", "AI Slots"),
            ("1", "AI Slots"),
            ("2", "AI Slots"),
            ("3", "AI Slots"),
            ("4", "AI Slots"),
            ("5", "AI Slots"),
            ("6", "AI Slots"),
            ("7", "AI Slots"),
            ("8", "AI Slots")
        };

        public AiAgentStatusCommand()
        {
            this.SetWidget(true);
            this.DisplayName = "";
            this.Description = "";
            foreach (var item in Items) this.AddParameter(item.Key, "", item.Group);
        }

        protected override bool OnLoad()
        {
            DeckClient.StateUpdated += OnStateUpdated;
            DeckClient.EnsurePolling();
            return true;
        }

        protected override bool OnUnload()
        {
            DeckClient.StateUpdated -= OnStateUpdated;
            return true;
        }

        private void OnStateUpdated()
        {
            this.ActionImageChanged();
        }

        protected override BitmapImage GetCommandImage(string parameter, PluginImageSize imageSize)
        {
            return DeckClient.Render(parameter, imageSize);
        }

        protected override string GetCommandDisplayName(string actionParameter, PluginImageSize imageSize)
        {
            return string.Empty;
        }

        private void Press(string actionParameter)
        {
            var key = string.IsNullOrWhiteSpace(actionParameter) ? "0" : actionParameter.Trim();
            DeckClient.Post("/press/" + Uri.EscapeDataString(key));
            this.ActionImageChanged();
        }

        [Obsolete]
        protected override bool ProcessButtonEvent(string actionParameter, DeviceButtonEvent buttonEvent)
        {
            var key = string.IsNullOrWhiteSpace(actionParameter) ? "0" : actionParameter.Trim();
            if (DeckClient.NeedsHold(key))
            {
                if (buttonEvent.IsPressed) DeckClient.BeginHold(key); else DeckClient.EndHold(key);
                return true;
            }
            if (buttonEvent.IsPressed) this.Press(actionParameter);
            return true;
        }

        protected override bool ProcessButtonEvent2(string actionParameter, DeviceButtonEvent2 buttonEvent)
        {
            var key = string.IsNullOrWhiteSpace(actionParameter) ? "0" : actionParameter.Trim();
            if (DeckClient.NeedsHold(key))
            {
                if (buttonEvent.EventType == DeviceButtonEventType.Press) DeckClient.BeginHold(key);
                else if (buttonEvent.EventType == DeviceButtonEventType.Release || buttonEvent.EventType.ToString() == "LongRelease") DeckClient.EndHold(key);
                return true;
            }
            if (buttonEvent.EventType == DeviceButtonEventType.Press) this.Press(actionParameter);
            return true;
        }

        protected override bool ProcessTouchEvent(string actionParameter, DeviceTouchEvent touchEvent)
        {
            var key = string.IsNullOrWhiteSpace(actionParameter) ? "0" : actionParameter.Trim();
            if (DeckClient.NeedsHold(key))
            {
                var name = touchEvent.EventType.ToString();
                if (name == "TouchDown") DeckClient.BeginHold(key);
                else if (name == "TouchUp" || name == "Tap" || name == "LongRelease") DeckClient.EndHold(key);
                return true;
            }
            if (touchEvent.EventType == DeviceTouchEventType.Tap) this.Press(actionParameter);
            return true;
        }

        protected override void RunCommand(string parameter)
        {
            var key = string.IsNullOrWhiteSpace(parameter) ? "0" : parameter.Trim();
            if (!DeckClient.NeedsHold(key)) this.Press(parameter);
        }
    }

    public class AiAgentDialAdjustment : PluginDynamicAdjustment
    {
        public AiAgentDialAdjustment() : base(hasReset: true)
        {
        }

        protected override bool OnLoad()
        {
            DeckClient.StateUpdated += this.AdjustmentValueChanged;
            DeckClient.EnsurePolling();
            return true;
        }

        protected override bool OnUnload()
        {
            DeckClient.StateUpdated -= this.AdjustmentValueChanged;
            return true;
        }

        protected override string GetAdjustmentValue(string parameter) => "";
        protected override string GetAdjustmentDisplayName(string actionParameter, PluginImageSize imageSize) => "";
        protected override string GetCommandDisplayName(string actionParameter, PluginImageSize imageSize) => "";

        protected override BitmapImage GetAdjustmentImage(string parameter, PluginImageSize imageSize)
        {
            return DeckClient.Render(parameter, imageSize, dial: true);
        }

        protected override void ApplyAdjustment(string parameter, int ticks)
        {
            var delta = ticks > 0 ? 1 : -1;
            DeckClient.Post("/dial/turn?delta=" + delta);
            this.AdjustmentValueChanged();
        }

        protected override void RunCommand(string parameter)
        {
            DeckClient.Post("/dial/press");
        }
    }

    public class AiAgentFolder : PluginDynamicFolder
    {
        public AiAgentFolder()
        {
            this.DisplayName = "AI Agents";
            this.Description = "Live status for the coding agents on this Mac";
        }

        public override PluginDynamicFolderNavigation GetNavigationArea(DeviceType _) => PluginDynamicFolderNavigation.ButtonArea;

        public override IEnumerable<string> GetButtonPressActionNames(DeviceType deviceType)
        {
            return new[]
            {
                PluginDynamicFolder.NavigateUpActionName,
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___antigravity",
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___claude",
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___cursor",
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___gemini",
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___codex",
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___summary",
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___approve",
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___deny",
                "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___dashboard"
            };
        }

        public override IEnumerable<string> GetEncoderRotateActionNames(DeviceType deviceType)
        {
            return new[] { "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentDialAdjustment" };
        }

        public override IEnumerable<string> GetEncoderPressActionNames(DeviceType deviceType)
        {
            return new[] { "$Reset___AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentDialAdjustment" };
        }
    }
}
