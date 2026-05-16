# Broadcast email templates

This directory holds renderer functions for outbound marketing /
announcement emails. Each template ends up in the admin
`/admin/broadcast` picker once registered in `index.ts`.

## Adding a template

1. Create `src/marketing/templates/your_template.ts` exporting a
   render function that returns `{ subject, html, text }`. The
   function takes `{ recipientUserId, recipientName }` so it can
   embed a per-recipient unsubscribe token via
   `makeUnsubscribeToken` from `../unsubscribe-token`.

2. Register it in `index.ts`:

   ```ts
   import { renderYourTemplate } from './your_template';

   export const templates: TemplateRenderer[] = [
     {
       key: 'your_template',          // stored in broadcasts.template_key
       label: 'Your template',         // shown in admin UI
       description: 'One-liner ops can read at a glance.',
       render: renderYourTemplate,
     },
   ];
   ```

3. Visit `/admin/broadcast`, click **Preview** to verify rendering,
   then **Send** when ready.

## Conventions

- Inline-style HTML only — most email clients ignore `<style>` blocks
  and external CSS. The Google Fonts `@import` works on Apple Mail
  and silently fails everywhere else, which is fine if you provide
  a fallback font stack.
- Always provide a plain-text version. Some clients + spam scanners
  read the text part for parity.
- Include the unsubscribe URL in the footer AND the
  `List-Unsubscribe` / `List-Unsubscribe-Post` headers (handled
  automatically by `send.ts`).
- Sends are paced at one per ~600ms to stay under Resend's free-tier
  rate limit.
