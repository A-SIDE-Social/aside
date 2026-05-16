// Re-exports for the marketing module so call sites import from
// one path: `import { sendBroadcast, templates } from '../marketing'`.

export {
  sendBroadcast,
  allOptedInRecipients,
  type BroadcastResult,
  type BroadcastRecipient,
} from './send';
export { templates, findTemplate, type TemplateRenderer, type RenderedEmail } from './templates';
export {
  makeUnsubscribeToken,
  verifyUnsubscribeToken,
} from './unsubscribe-token';
