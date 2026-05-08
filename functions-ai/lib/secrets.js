"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.AI_SECRETS = exports.OPENAI_API_KEY = void 0;
const params_1 = require("firebase-functions/params");
exports.OPENAI_API_KEY = (0, params_1.defineSecret)('OPENAI_API_KEY');
exports.AI_SECRETS = [exports.OPENAI_API_KEY];
//# sourceMappingURL=secrets.js.map