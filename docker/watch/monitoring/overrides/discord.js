const NotificationProvider = require("./notification-provider");
const axios = require("axios");
const { DOWN, UP } = require("../../src/util");

function fieldValue(value) {
    return String(value ?? "N/A").slice(0, 1024);
}

function discordTimestamp(value) {
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? new Date().toISOString() : parsed.toISOString();
}

class Discord extends NotificationProvider {

    name = "discord";

    async send(notification, msg, monitorJSON = null, heartbeatJSON = null) {
        const okMsg = "Sent Successfully.";

        try {
            const discordDisplayName = notification.discordUsername || "Uptime Kuma";

            if (heartbeatJSON == null) {
                await axios.post(notification.discordWebhookUrl, {
                    username: discordDisplayName,
                    content: msg,
                });
                return okMsg;
            }

            let address;
            switch (monitorJSON.type) {
                case "ping":
                    address = monitorJSON.hostname;
                    break;
                case "port":
                case "dns":
                case "gamedig":
                case "steam":
                    address = monitorJSON.hostname;
                    if (monitorJSON.port) {
                        address += ":" + monitorJSON.port;
                    }
                    break;
                case "push":
                    address = "Heartbeat";
                    break;
                default:
                    address = monitorJSON.url;
                    break;
            }

            const isDown = heartbeatJSON.status === DOWN;
            const isUp = heartbeatJSON.status === UP;
            if (!isDown && !isUp) {
                return okMsg;
            }

            const fields = [
                { name: "Service Name", value: fieldValue(monitorJSON.name) },
                {
                    name: monitorJSON.type === "push" ? "Service Type" : "Service URL",
                    value: fieldValue(address),
                },
                {
                    name: `Time (${fieldValue(heartbeatJSON.timezone)})`,
                    value: fieldValue(heartbeatJSON.localDateTime),
                },
            ];
            fields.push(isDown
                ? { name: "Error", value: fieldValue(heartbeatJSON.msg) }
                : { name: "Ping", value: heartbeatJSON.ping == null ? "N/A" : fieldValue(heartbeatJSON.ping + " ms") });

            const data = {
                username: discordDisplayName,
                embeds: [{
                    title: isDown
                        ? "❌ Your service " + fieldValue(monitorJSON.name) + " went down. ❌"
                        : "✅ Your service " + fieldValue(monitorJSON.name) + " is up! ✅",
                    color: isDown ? 16711680 : 65280,
                    timestamp: discordTimestamp(heartbeatJSON.time),
                    fields,
                }],
            };
            if (notification.discordPrefixMessage) {
                data.content = notification.discordPrefixMessage;
            }
            await axios.post(notification.discordWebhookUrl, data);
            return okMsg;
        } catch (error) {
            this.throwGeneralAxiosError(error);
        }
    }
}

module.exports = Discord;
