# WayDrop Technical Documentation — Real-time WebSockets Sync

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead Real-time Architect  
**Applies To Commit:** 241d836  

---

## 1. WebSockets Engine & Channel Multiplexing

WayDrop uses **Supabase Realtime** to sync database changes to client applications over a single WebSocket connection. 

Instead of opening multiple connections for different tables, the client's **`RealtimeManager`** multiplexes subscriptions through a single socket connection. Subscriptions are grouped into targeted **Real-time Channels** (e.g. `order_tracking`, `chat_room`, `rider_positions`) using table row-level filters:

- **Order Tracking Channel:** Listens for changes on the `orders` table where `id = current_order_id`.
- **Chat Channel:** Listens for inserts on the `order_chat_messages` table where `order_id = current_order_id`.
- **Rider Positions Channel:** Listens for updates on the `riders` table within the active passenger's geofence boundaries.

---

## 2. Custom Reconnect & Exponential Backoff Logic

In poor network conditions (e.g. traveling passengers), WebSockets can disconnect frequently. To manage this without overloading the server, the **`RealtimeManager`** implements a **Truncated Exponential Backoff Reconnection Algorithm**:

### 2.1. Backoff Parameters
- **Base Backoff Delay ($T_{\text{base}}$):** 1 second.
- **Backoff Multiplier ($M$):** 2.0.
- **Maximum Reconnect Delay ($T_{\text{max}}$):** 30 seconds.
- **Jitter Ratio ($J$):** $\pm 10\%$ random variance added to prevent connection spikes from multiple devices reconnecting at once.

The reconnection delay ($T_n$) for attempt $n$ is calculated as:

$$T_n = \min\left(T_{\text{base}} \times M^n \pm \text{RandomJitter}, T_{\text{max}}\right)$$

### 2.2. Reconnect States
- **`connected`:** Socket active. Reset retry counter to 0.
- **`disconnected`:** Connection lost. Start the reconnection timer.
- **`reconnecting`:** Attempting to establish a socket connection.

---

## 3. Heartbeat & Health Check Pings

To detect silent failures (where the socket connection appears open but no data is flowing), the client implements a **Heartbeat Monitor**:

1. **Ping Interval:** Every 30 seconds, the client sends a small `ping` payload to the Supabase Realtime server.
2. **Pong Timeout:** The client awaits a `pong` response from the server.
3. **Forced Disconnect:** If the `pong` is not received within 10 seconds:
   - The socket is marked stale.
   - The connection is closed.
   - The reconnection loop is triggered.
4. **App Lifecycle Hooks:** The heartbeat monitor pauses when the app goes into the background, and triggers an immediate ping when the app resumes.
