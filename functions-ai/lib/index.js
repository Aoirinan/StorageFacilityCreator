"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.aiAssistantExecuteAction = exports.aiAssistantChat = exports.aiAssistant = void 0;
const init_1 = require("@sfc/functions-shared/init");
(0, init_1.ensureFirebaseAdminApp)();
(0, init_1.ensureSentryForFunctions)();
var aiHandlers_1 = require("./aiHandlers");
Object.defineProperty(exports, "aiAssistant", { enumerable: true, get: function () { return aiHandlers_1.aiAssistant; } });
Object.defineProperty(exports, "aiAssistantChat", { enumerable: true, get: function () { return aiHandlers_1.aiAssistantChat; } });
Object.defineProperty(exports, "aiAssistantExecuteAction", { enumerable: true, get: function () { return aiHandlers_1.aiAssistantExecuteAction; } });
//# sourceMappingURL=index.js.map