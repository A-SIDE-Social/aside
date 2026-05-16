// Template registry. Maps a template_key (stored in `broadcasts`)
// to the renderer function. Adding a new template is a 2-line
// change here + a new file in this directory.
//
// Empty by default in the open-source distribution — operators add
// their own templates for their own product. See README.md in this
// directory for the renderer signature.

export interface RenderedEmail {
  subject: string;
  html: string;
  text: string;
}

export interface TemplateRenderer {
  /// Stable key — also stored in broadcasts.template_key. Don't
  /// rename existing entries; deprecate + add new one if a template
  /// substantively changes.
  key: string;
  /// Display name for the admin /admin/broadcast picker.
  label: string;
  /// One-line description shown on the picker so the operator can
  /// remember what's inside without opening the file.
  description: string;
  /// Renders the email for a specific recipient. The recipient's
  /// user_id is required so the unsubscribe token can be embedded.
  render: (vars: { recipientUserId: string; recipientName: string }) => RenderedEmail;
}

export const templates: TemplateRenderer[] = [];

export function findTemplate(key: string): TemplateRenderer | undefined {
  return templates.find((t) => t.key === key);
}
