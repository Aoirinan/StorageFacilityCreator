"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.appendAiChatAuditLog = appendAiChatAuditLog;
const admin = __importStar(require("firebase-admin"));
const functions = __importStar(require("firebase-functions/v1"));
/**
 * Persists one AI user/assistant turn for super-admin review (Admin SDK; not client-writable).
 * Failures are logged and swallowed so chat UX is not blocked by audit storage.
 */
async function appendAiChatAuditLog(params) {
    var _a, _b;
    try {
        await admin
            .firestore()
            .collection('facilities')
            .doc(params.facilityId)
            .collection('aiChatAuditLogs')
            .add({
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            facilityId: params.facilityId,
            facilityName: (_a = params.facilityName) !== null && _a !== void 0 ? _a : null,
            userId: params.userId,
            userEmail: (_b = params.userEmail) !== null && _b !== void 0 ? _b : null,
            userMessage: params.userMessage,
            assistantReply: params.assistantReply,
            requestId: params.requestId,
            model: params.model,
            tokensUsed: params.tokensUsed,
            latencyMs: params.latencyMs,
            providerUsed: params.providerUsed,
            source: params.source,
        });
    }
    catch (e) {
        const err = e;
        functions.logger.error('appendAiChatAuditLog failed', {
            facilityId: params.facilityId,
            error: err === null || err === void 0 ? void 0 : err.message,
        });
    }
}
//# sourceMappingURL=aiChatAuditLog.js.map