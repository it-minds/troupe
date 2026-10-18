// A WebSocket for an app's test under jsdom, from the package that already depends on
// `ws`: the console's tests open a relayed session's socket (troupe #58) and have no `ws`
// of their own, and Node's own WebSocket does not take jsdom's events.

export { WebSocket as NodeWebSocket } from "ws";
