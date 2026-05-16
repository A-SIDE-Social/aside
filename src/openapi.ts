import swaggerUi from 'swagger-ui-express';
import { Express } from 'express';

export const openApiSpec = {
  openapi: '3.0.3',
  info: {
    title: 'A/SIDE API',
    version: '1.0.0',
    description: 'API for A/SIDE, an invite-only social network built around mutual follows, groups, stories, and direct messaging.',
  },
  servers: [
    { url: '/v1', description: 'V1 API' },
  ],
  components: {
    securitySchemes: {
      BearerAuth: {
        type: 'http' as const,
        scheme: 'bearer',
        bearerFormat: 'JWT',
      },
    },
    schemas: {
      User: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          display_name: { type: 'string' },
          avatar_url: { type: 'string', nullable: true },
          bio: { type: 'string', nullable: true },
          email: { type: 'string' },
          push_token: { type: 'string', nullable: true },
          subscription_status: { type: 'string', enum: ['free', 'active', 'expired', 'cancelled'] },
          trial_ends_at: { type: 'string', format: 'date-time', nullable: true },
          referral_bonus_granted_at: { type: 'string', format: 'date-time', nullable: true },
          created_at: { type: 'string', format: 'date-time' },
          updated_at: { type: 'string', format: 'date-time' },
          deleted_at: { type: 'string', format: 'date-time', nullable: true },
        },
      },
      PlanLimits: {
        type: 'object' as const,
        description: 'Current plan limits for the authenticated user. feed_history_days is null for unlimited (paid/trial).',
        properties: {
          feed_history_days: { type: 'integer', nullable: true, description: 'Number of days of feed history visible, or null for unlimited' },
          max_photos_per_post: { type: 'integer' },
          max_groups: { type: 'integer' },
          max_video_story_seconds: { type: 'integer' },
          max_invites: { type: 'integer' },
          max_bio_length: { type: 'integer' },
          max_caption_length: { type: 'integer' },
          max_comment_length: { type: 'integer' },
          max_group_name_length: { type: 'integer' },
          story_expiration_hours: { type: 'integer' },
        },
      },
      UserProfile: {
        type: 'object' as const,
        description: 'Public profile. bio is included only for mutual follows.',
        properties: {
          id: { type: 'string', format: 'uuid' },
          display_name: { type: 'string' },
          avatar_url: { type: 'string', nullable: true },
          bio: { type: 'string', nullable: true },
          is_mutual_follow: { type: 'boolean' },
          is_following: { type: 'boolean' },
          is_followed_by: { type: 'boolean', description: 'True if this user follows the authenticated user' },
          mutual_follow_count: { type: 'integer' },
        },
      },
      Post: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          user_id: { type: 'string', format: 'uuid' },
          caption: { type: 'string', nullable: true },
          display_name: { type: 'string' },
          avatar_url: { type: 'string', nullable: true },
          media: { type: 'array', items: { $ref: '#/components/schemas/PostMedia' } },
          comment_count: { type: 'integer', description: 'Total number of comments on this post (feed only)' },
          recent_comments: { type: 'array', items: { $ref: '#/components/schemas/CommentPreview' }, description: 'Latest 2 comments with display name and avatar (feed only)' },
          created_at: { type: 'string', format: 'date-time' },
          updated_at: { type: 'string', format: 'date-time' },
          deleted_at: { type: 'string', format: 'date-time', nullable: true },
        },
      },
      CommentPreview: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          user_id: { type: 'string', format: 'uuid' },
          body: { type: 'string' },
          display_name: { type: 'string' },
          avatar_url: { type: 'string', nullable: true },
          created_at: { type: 'string', format: 'date-time' },
        },
      },
      PostMedia: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          post_id: { type: 'string', format: 'uuid' },
          position: { type: 'integer' },
          media_url: { type: 'string' },
          media_type: { type: 'string', enum: ['photo', 'video'] },
          width: { type: 'integer', nullable: true },
          height: { type: 'integer', nullable: true },
          created_at: { type: 'string', format: 'date-time' },
        },
      },
      MediaInput: {
        type: 'object' as const,
        required: ['key', 'media_type', 'position'],
        properties: {
          key: { type: 'string', description: 'The key returned from upload-url' },
          media_type: { type: 'string', enum: ['photo', 'video'] },
          width: { type: 'integer', nullable: true },
          height: { type: 'integer', nullable: true },
          position: { type: 'integer' },
        },
      },
      Comment: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          post_id: { type: 'string', format: 'uuid' },
          user_id: { type: 'string', format: 'uuid' },
          body: { type: 'string' },
          display_name: { type: 'string' },
          avatar_url: { type: 'string', nullable: true },
          created_at: { type: 'string', format: 'date-time' },
          updated_at: { type: 'string', format: 'date-time', nullable: true },
          deleted_at: { type: 'string', format: 'date-time', nullable: true },
          reply_to_comment_id: { type: 'string', format: 'uuid', nullable: true },
          reply_to_user_id: { type: 'string', format: 'uuid', nullable: true },
          reply_to_display_name: { type: 'string', nullable: true },
          like_count: { type: 'integer', minimum: 0 },
          is_liked: { type: 'boolean' },
        },
      },
      Story: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          user_id: { type: 'string', format: 'uuid' },
          media_url: { type: 'string' },
          media_type: { type: 'string', enum: ['photo', 'video'] },
          expires_at: { type: 'string', format: 'date-time' },
          created_at: { type: 'string', format: 'date-time' },
        },
      },
      GroupedStories: {
        type: 'object' as const,
        properties: {
          user: { $ref: '#/components/schemas/UserProfile' },
          stories: { type: 'array', items: { $ref: '#/components/schemas/Story' } },
        },
      },
      Conversation: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          conversation_type: { type: 'string', enum: ['direct', 'group'] },
          // Group-only: name (1–50 chars) and created_by. Null for directs.
          name: { type: 'string', nullable: true },
          created_by: { type: 'string', format: 'uuid', nullable: true },
          // Direct-only: 2-party columns. Null for groups.
          user_a_id: { type: 'string', format: 'uuid', nullable: true },
          user_b_id: { type: 'string', format: 'uuid', nullable: true },
          created_at: { type: 'string', format: 'date-time' },
          last_message_at: { type: 'string', format: 'date-time', nullable: true },
          last_read_at: { type: 'string', format: 'date-time', nullable: true },
          unread_count: { type: 'integer' },
          // Direct-only enrichments (null for groups).
          other_user_id: { type: 'string', format: 'uuid', nullable: true },
          other_display_name: { type: 'string', nullable: true },
          other_avatar_url: { type: 'string', nullable: true },
          // Group-only enrichment (null for directs).
          members: {
            type: 'array',
            nullable: true,
            items: { $ref: '#/components/schemas/UserProfile' },
          },
        },
      },
      Message: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          conversation_id: { type: 'string', format: 'uuid' },
          sender_id: { type: 'string', format: 'uuid' },
          body: { type: 'string', nullable: true },
          media_url: { type: 'string', nullable: true },
          sender_display_name: { type: 'string' },
          sender_avatar_url: { type: 'string', nullable: true },
          created_at: { type: 'string', format: 'date-time' },
          deleted_at: { type: 'string', format: 'date-time', nullable: true },
        },
      },
      Group: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          user_id: { type: 'string', format: 'uuid' },
          name: { type: 'string' },
          color: { type: 'string', nullable: true },
          position: { type: 'integer', nullable: true },
          created_at: { type: 'string', format: 'date-time' },
          updated_at: { type: 'string', format: 'date-time' },
        },
      },
      Invite: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          created_by_user_id: { type: 'string', format: 'uuid' },
          used_by_user_id: { type: 'string', format: 'uuid', nullable: true },
          code: { type: 'string' },
          status: { type: 'string', enum: ['pending', 'used', 'expired', 'revoked'] },
          expires_at: { type: 'string', format: 'date-time', nullable: true },
          used_at: { type: 'string', format: 'date-time', nullable: true },
          created_at: { type: 'string', format: 'date-time' },
        },
      },
      Follow: {
        type: 'object' as const,
        properties: {
          id: { type: 'string', format: 'uuid' },
          follower_id: { type: 'string', format: 'uuid' },
          followee_id: { type: 'string', format: 'uuid' },
          created_at: { type: 'string', format: 'date-time' },
        },
      },
      InboundFollow: {
        type: 'object' as const,
        description: 'A user who follows you but you do not follow back.',
        properties: {
          id: { type: 'string', format: 'uuid' },
          display_name: { type: 'string' },
          avatar_url: { type: 'string', nullable: true },
        },
      },
      Error: {
        type: 'object' as const,
        properties: {
          error: { type: 'string' },
        },
      },
    },
  },
  paths: {
    // ─── Auth ───────────────────────────────────────────────────────────
    '/auth/request-otp': {
      post: {
        tags: ['Auth'],
        summary: 'Request a one-time password',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['email'],
                properties: {
                  email: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'OTP sent',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    '/auth/verify-otp': {
      post: {
        tags: ['Auth'],
        summary: 'Verify OTP and authenticate or register',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['email', 'code'],
                properties: {
                  email: { type: 'string' },
                  code: { type: 'string' },
                  invite_code: { type: 'string', description: 'Optional for new registrations' },
                  display_name: { type: 'string', description: 'Required for new registrations' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Authenticated successfully',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    access_token: { type: 'string' },
                    refresh_token: { type: 'string' },
                    user: { $ref: '#/components/schemas/User' },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/auth/refresh': {
      post: {
        tags: ['Auth'],
        summary: 'Refresh an access token',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['refresh_token'],
                properties: {
                  refresh_token: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'New access token',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    access_token: { type: 'string' },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/auth/session': {
      delete: {
        tags: ['Auth'],
        summary: 'End a session (logout)',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['refresh_token'],
                properties: {
                  refresh_token: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Session ended',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },

    // ─── Users ──────────────────────────────────────────────────────────
    '/users/me': {
      get: {
        tags: ['Users'],
        summary: 'Get the current user with plan limits',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Current user and plan limits',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { user: { $ref: '#/components/schemas/User' }, plan_limits: { $ref: '#/components/schemas/PlanLimits' } } } } },
          },
        },
      },
      patch: {
        tags: ['Users'],
        summary: 'Update the current user profile',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                properties: {
                  display_name: { type: 'string' },
                  bio: { type: 'string' },
                  avatar_url: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Updated user',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { user: { $ref: '#/components/schemas/User' } } } } },
          },
        },
      },
      delete: {
        tags: ['Users'],
        summary: 'Soft-delete the current user account',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Account deleted',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    '/users/me/upload-url': {
      post: {
        tags: ['Users'],
        summary: 'Get presigned upload URL for avatar media',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['content_type'],
                properties: {
                  content_type: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Upload URL',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    upload_url: { type: 'string' },
                    key: { type: 'string' },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/users/{id}': {
      get: {
        tags: ['Users'],
        summary: 'Get a user profile by ID',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'User profile (bio included only for mutual follows)',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { user: { $ref: '#/components/schemas/UserProfile' } } } } },
          },
        },
      },
    },

    // ─── Follows ────────────────────────────────────────────────────────
    '/follows': {
      post: {
        tags: ['Follows'],
        summary: 'Follow a user',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['user_id'],
                properties: {
                  user_id: { type: 'string', format: 'uuid' },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'Follow created',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    follow: { $ref: '#/components/schemas/Follow' },
                    is_mutual: { type: 'boolean' },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/follows/{user_id}': {
      delete: {
        tags: ['Follows'],
        summary: 'Unfollow a user',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'user_id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Unfollowed',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    '/follows/mutual': {
      get: {
        tags: ['Follows'],
        summary: 'List mutual follows',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Mutual follows',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    users: { type: 'array', items: { $ref: '#/components/schemas/UserProfile' } },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/follows/inbound': {
      get: {
        tags: ['Follows'],
        summary: 'List inbound follows (users who follow you but you do not follow back)',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Inbound follows',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    users: { type: 'array', items: { $ref: '#/components/schemas/InboundFollow' } },
                  },
                },
              },
            },
          },
        },
      },
    },

    '/follows/outbound': {
      get: {
        tags: ['Follows'],
        summary: 'List outbound follows (users you follow who do not follow you back)',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Outbound follows',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    users: { type: 'array', items: { $ref: '#/components/schemas/InboundFollow' } },
                  },
                },
              },
            },
          },
        },
      },
    },

    // ─── Invites ────────────────────────────────────────────────────────
    '/invites': {
      get: {
        tags: ['Invites'],
        summary: 'List current user invites',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Invites list',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    invites: { type: 'array', items: { $ref: '#/components/schemas/Invite' } },
                  },
                },
              },
            },
          },
        },
      },
      post: {
        tags: ['Invites'],
        summary: 'Generate a new invite code',
        security: [{ BearerAuth: [] }],
        responses: {
          '201': {
            description: 'Invite created',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { invite: { $ref: '#/components/schemas/Invite' } } } } },
          },
        },
      },
    },
    '/invites/{id}': {
      delete: {
        tags: ['Invites'],
        summary: 'Revoke a pending invite',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Invite revoked',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    '/invites/validate/{code}': {
      get: {
        tags: ['Invites'],
        summary: 'Validate an invite code (no auth required)',
        parameters: [
          { name: 'code', in: 'path' as const, required: true, schema: { type: 'string' } },
        ],
        responses: {
          '200': {
            description: 'Validation result',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    valid: { type: 'boolean' },
                    inviter: {
                      type: 'object',
                      nullable: true,
                      properties: {
                        username: { type: 'string' },
                        display_name: { type: 'string' },
                      },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },

    '/invites/redeem': {
      post: {
        tags: ['Invites'],
        summary: 'Redeem an invite code as an existing user to connect with the inviter',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['code'],
                properties: {
                  code: { type: 'string', description: 'The invite code to redeem' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Invite redeemed',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    message: { type: 'string' },
                    is_mutual: { type: 'boolean', description: 'True if both users now follow each other' },
                  },
                },
              },
            },
          },
          '400': { description: 'Cannot redeem own invite', content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } } },
          '404': { description: 'Invalid or expired code', content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } } },
          '409': { description: 'Already connected', content: { 'application/json': { schema: { $ref: '#/components/schemas/Error' } } } },
        },
      },
    },

    // ─── Feed ───────────────────────────────────────────────────────────
    '/feed': {
      get: {
        tags: ['Feed'],
        summary: 'Get the chronological feed from mutual follows',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'before', in: 'query' as const, required: false, schema: { type: 'string', format: 'date-time' }, description: 'Cursor for pagination; return posts created before this timestamp' },
          { name: 'group_id', in: 'query' as const, required: false, schema: { type: 'string', format: 'uuid' }, description: 'Filter to posts by members of this group' },
        ],
        responses: {
          '200': {
            description: 'Feed posts',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    posts: { type: 'array', items: { $ref: '#/components/schemas/Post' } },
                  },
                },
              },
            },
          },
        },
      },
    },

    // ─── Posts ───────────────────────────────────────────────────────────
    '/posts/upload-url': {
      post: {
        tags: ['Posts'],
        summary: 'Get presigned upload URL(s) for post media',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['content_type'],
                properties: {
                  content_type: { type: 'string', description: 'MIME type, e.g. image/jpeg' },
                  count: { type: 'integer', minimum: 1, maximum: 5, default: 1 },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Upload URLs',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    uploads: {
                      type: 'array',
                      items: {
                        type: 'object',
                        properties: {
                          upload_url: { type: 'string' },
                          key: { type: 'string' },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/posts': {
      post: {
        tags: ['Posts'],
        summary: 'Create a new post',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['media'],
                properties: {
                  caption: { type: 'string', maxLength: 2200 },
                  media: { type: 'array', items: { $ref: '#/components/schemas/MediaInput' }, minItems: 1, maxItems: 5 },
                  group_ids: { type: 'array', items: { type: 'string', format: 'uuid' }, description: 'Scope post visibility to these groups' },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'Post created',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { post: { $ref: '#/components/schemas/Post' } } } } },
          },
        },
      },
    },
    '/posts/{id}': {
      get: {
        tags: ['Posts'],
        summary: 'Get a post by ID',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Post',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { post: { $ref: '#/components/schemas/Post' } } } } },
          },
        },
      },
      patch: {
        tags: ['Posts'],
        summary: 'Edit own post caption',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: { 'application/json': { schema: { type: 'object' as const, properties: { caption: { type: 'string', maxLength: 2200 } } } } },
        },
        responses: {
          '200': {
            description: 'Post updated',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { post: { $ref: '#/components/schemas/Post' } } } } },
          },
        },
      },
      delete: {
        tags: ['Posts'],
        summary: 'Delete a post',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Post deleted',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    '/posts/by-user/{id}': {
      get: {
        tags: ['Posts'],
        summary: 'Get posts by a user',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
          { name: 'before', in: 'query' as const, required: false, schema: { type: 'string', format: 'date-time' }, description: 'Cursor for pagination' },
        ],
        responses: {
          '200': {
            description: 'Posts by user',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    posts: { type: 'array', items: { $ref: '#/components/schemas/Post' } },
                  },
                },
              },
            },
          },
        },
      },
    },

    // ─── Comments ───────────────────────────────────────────────────────
    '/posts/{postId}/comments': {
      get: {
        tags: ['Comments'],
        summary: 'List comments on a post',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'postId', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Comments list',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    comments: { type: 'array', items: { $ref: '#/components/schemas/Comment' } },
                  },
                },
              },
            },
          },
        },
      },
      post: {
        tags: ['Comments'],
        summary: 'Create a comment on a post',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'postId', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['body'],
                properties: {
                  body: { type: 'string', maxLength: 1000 },
                  reply_to_comment_id: {
                    type: 'string',
                    format: 'uuid',
                    nullable: true,
                    description: 'If set, the comment is a reply — parent must belong to the same post and not be deleted.',
                  },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'Comment created',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { comment: { $ref: '#/components/schemas/Comment' } } } } },
          },
        },
      },
    },
    '/comments/{id}': {
      put: {
        tags: ['Comments'],
        summary: 'Edit own comment',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: { 'application/json': { schema: { type: 'object' as const, required: ['body'], properties: { body: { type: 'string', maxLength: 1000 } } } } },
        },
        responses: {
          '200': {
            description: 'Comment updated',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { comment: { $ref: '#/components/schemas/Comment' } } } } },
          },
        },
      },
      delete: {
        tags: ['Comments'],
        summary: 'Delete a comment',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Comment deleted',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    '/comments/{id}/like': {
      post: {
        tags: ['Comments'],
        summary: 'Like a comment (idempotent)',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Comment liked',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    liked: { type: 'boolean' },
                    like_count: { type: 'integer', minimum: 0 },
                  },
                },
              },
            },
          },
        },
      },
      delete: {
        tags: ['Comments'],
        summary: 'Unlike a comment',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Comment unliked',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    liked: { type: 'boolean' },
                    like_count: { type: 'integer', minimum: 0 },
                  },
                },
              },
            },
          },
        },
      },
    },

    // ─── Stories ─────────────────────────────────────────────────────────
    '/stories': {
      get: {
        tags: ['Stories'],
        summary: 'List active stories from mutual follows, grouped by user',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Grouped stories',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    story_groups: { type: 'array', items: { $ref: '#/components/schemas/GroupedStories' } },
                  },
                },
              },
            },
          },
        },
      },
      post: {
        tags: ['Stories'],
        summary: 'Create a story',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['media_url', 'media_type'],
                properties: {
                  media_url: { type: 'string' },
                  media_type: { type: 'string', enum: ['photo', 'video'] },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'Story created',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { story: { $ref: '#/components/schemas/Story' } } } } },
          },
        },
      },
    },
    '/stories/upload-url': {
      post: {
        tags: ['Stories'],
        summary: 'Get presigned upload URL for story media',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['content_type'],
                properties: {
                  content_type: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Upload URL',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    upload_url: { type: 'string' },
                    key: { type: 'string' },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/stories/{id}': {
      delete: {
        tags: ['Stories'],
        summary: 'Delete a story',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Story deleted',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },

    // ─── Conversations ──────────────────────────────────────────────────
    '/conversations': {
      get: {
        tags: ['Conversations'],
        summary: 'List conversations for the current user',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Conversations list',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    conversations: { type: 'array', items: { $ref: '#/components/schemas/Conversation' } },
                  },
                },
              },
            },
          },
        },
      },
      post: {
        tags: ['Conversations'],
        summary: 'Create or get a conversation. Direct (user_id) or group (member_ids + name).',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                description: 'Exactly one of user_id OR (member_ids + name) should be provided.',
                properties: {
                  // Direct path.
                  user_id: { type: 'string', format: 'uuid', nullable: true },
                  // Group path.
                  member_ids: {
                    type: 'array',
                    nullable: true,
                    items: { type: 'string', format: 'uuid' },
                    description: 'User ids to include as members (excluding the creator). 1–9 others, all must be mutual follows.',
                  },
                  name: { type: 'string', nullable: true, maxLength: 50 },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Existing direct conversation returned',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { conversation: { $ref: '#/components/schemas/Conversation' } } } } },
          },
          '201': {
            description: 'New conversation created',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { conversation: { $ref: '#/components/schemas/Conversation' } } } } },
          },
        },
      },
    },
    '/conversations/{id}': {
      get: {
        tags: ['Conversations'],
        summary: 'Single conversation by id',
        description:
          'Unlike GET /conversations (which filters by last_message_at ' +
          'IS NOT NULL), this returns a single conversation regardless ' +
          "of whether it has messages yet — used by the client's " +
          'detail screen on a freshly-created conversation before the ' +
          'first send.',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Conversation',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { conversation: { $ref: '#/components/schemas/Conversation' } } } } },
          },
          '404': { description: 'Conversation not found or not a member' },
        },
      },
      patch: {
        tags: ['Conversations'],
        summary: 'Rename a group conversation (creator only)',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['name'],
                properties: { name: { type: 'string', maxLength: 50 } },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Conversation renamed',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { conversation: { $ref: '#/components/schemas/Conversation' } } } } },
          },
        },
      },
    },
    '/conversations/{id}/members': {
      post: {
        tags: ['Conversations'],
        summary: 'Add members to a group conversation (creator only)',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['user_ids'],
                properties: {
                  user_ids: {
                    type: 'array',
                    items: { type: 'string', format: 'uuid' },
                  },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Members added',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { conversation: { $ref: '#/components/schemas/Conversation' } } } } },
          },
        },
      },
    },
    '/conversations/{id}/members/{userId}': {
      delete: {
        tags: ['Conversations'],
        summary: 'Remove a member from a group conversation (creator only)',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
          { name: 'userId', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Member removed',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    '/conversations/{id}/leave': {
      post: {
        tags: ['Conversations'],
        summary: 'Leave a group conversation. Dissolves the conversation if you were the last member.',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Left the conversation',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    message: { type: 'string' },
                    dissolved: { type: 'boolean' },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/conversations/{id}/messages': {
      get: {
        tags: ['Conversations'],
        summary: 'Get messages for a conversation',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
          { name: 'before', in: 'query' as const, required: false, schema: { type: 'string', format: 'date-time' }, description: 'Cursor for pagination' },
        ],
        responses: {
          '200': {
            description: 'Messages list',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    messages: { type: 'array', items: { $ref: '#/components/schemas/Message' } },
                  },
                },
              },
            },
          },
        },
      },
      post: {
        tags: ['Conversations'],
        summary: 'Send a message in a conversation',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                properties: {
                  body: { type: 'string' },
                  media_url: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'Message sent',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { $ref: '#/components/schemas/Message' } } } } },
          },
        },
      },
    },
    '/conversations/{id}/upload-url': {
      post: {
        tags: ['Conversations'],
        summary: 'Get presigned upload URL for conversation media',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['content_type'],
                properties: {
                  content_type: { type: 'string' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Upload URL',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    upload_url: { type: 'string' },
                    key: { type: 'string' },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/conversations/{id}/read': {
      post: {
        tags: ['Conversations'],
        summary: 'Mark a conversation as read',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Marked as read',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },

    // ─── Lists ──────────────────────────────────────────────────────────
    // User-facing name is "Lists" (curated friend lists used as post
    // audience + feed filter). Data model is internally named `groups`
    // for historical reasons — reserving "Groups" for DM group chats.
    // Legacy /groups paths still route to the same handlers server-side.
    '/lists': {
      get: {
        tags: ['Lists'],
        summary: 'List the current user\'s friend lists',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': {
            description: 'Groups list',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    groups: { type: 'array', items: { $ref: '#/components/schemas/Group' } },
                  },
                },
              },
            },
          },
        },
      },
      post: {
        tags: ['Lists'],
        summary: 'Create a list',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['name'],
                properties: {
                  name: { type: 'string', maxLength: 30 },
                  color: { type: 'string' },
                  position: { type: 'integer' },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'List created',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { group: { $ref: '#/components/schemas/Group' } } } } },
          },
        },
      },
    },
    '/lists/{id}': {
      patch: {
        tags: ['Lists'],
        summary: 'Update a list',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                properties: {
                  name: { type: 'string', maxLength: 30 },
                  color: { type: 'string' },
                  position: { type: 'integer' },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'List updated',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { group: { $ref: '#/components/schemas/Group' } } } } },
          },
        },
      },
      delete: {
        tags: ['Lists'],
        summary: 'Delete a list',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'List deleted',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    '/lists/{id}/members': {
      get: {
        tags: ['Lists'],
        summary: 'List the members of a list',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: 'Group members',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    members: { type: 'array', items: { $ref: '#/components/schemas/UserProfile' } },
                  },
                },
              },
            },
          },
        },
      },
      put: {
        tags: ['Lists'],
        summary: 'Replace the full member list of a list',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['user_ids'],
                properties: {
                  user_ids: { type: 'array', items: { type: 'string', format: 'uuid' } },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Members updated',
            content: { 'application/json': { schema: { type: 'object' as const, properties: { message: { type: 'string' } } } } },
          },
        },
      },
    },
    // ── E2EE key registry (Phase 1c) ──────────────────────────
    '/devices/keys/upload': {
      post: {
        tags: ['E2EE'],
        summary: 'Upload the initial key bundle (first-run only)',
        description:
          "Stores the user's identity key, signed prekey, one-time " +
          'prekey batch, and Kyber prekey batch (post-quantum hybrid). ' +
          'Returns 409 if an active key set already exists — caller ' +
          'should POST /devices/revoke first to reset.',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: [
                  'identity_key_pub',
                  'signed_prekey',
                  'one_time_prekeys',
                  'kyber_prekeys',
                ],
                properties: {
                  identity_key_pub: {
                    type: 'string',
                    description: 'Base64-encoded 33-byte libsignal IdentityKey',
                  },
                  signed_prekey: {
                    type: 'object' as const,
                    required: ['id', 'public', 'signature'],
                    properties: {
                      id: { type: 'integer' },
                      public: { type: 'string', description: 'base64 33 bytes' },
                      signature: { type: 'string', description: 'base64 64 bytes' },
                    },
                  },
                  one_time_prekeys: {
                    type: 'array',
                    maxItems: 200,
                    items: {
                      type: 'object' as const,
                      required: ['id', 'public'],
                      properties: {
                        id: { type: 'integer' },
                        public: { type: 'string', description: 'base64 33 bytes' },
                      },
                    },
                  },
                  kyber_prekeys: {
                    type: 'array',
                    minItems: 1,
                    maxItems: 100,
                    items: {
                      type: 'object' as const,
                      required: ['id', 'public', 'signature'],
                      properties: {
                        id: { type: 'integer' },
                        public: {
                          type: 'string',
                          description: 'base64 ~1568 bytes (Kyber1024)',
                        },
                        signature: { type: 'string', description: 'base64 64 bytes' },
                      },
                    },
                  },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Keys uploaded',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    message: { type: 'string' },
                    one_time_prekey_count: { type: 'integer' },
                    kyber_prekey_count: { type: 'integer' },
                  },
                },
              },
            },
          },
          '400': { description: 'Validation error (byte lengths, batch size, key ids)' },
          '409': { description: 'Active key set already exists' },
        },
      },
    },
    '/devices/keys/replenish': {
      post: {
        tags: ['E2EE'],
        summary: 'Add more OTPKs and/or Kyber prekeys',
        description:
          'At least one of the two arrays must be non-empty. Idempotent ' +
          'under (user_id, key_id) collisions — duplicate ids are skipped.',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                properties: {
                  one_time_prekeys: {
                    type: 'array',
                    items: {
                      type: 'object' as const,
                      properties: {
                        id: { type: 'integer' },
                        public: { type: 'string' },
                      },
                    },
                  },
                  kyber_prekeys: {
                    type: 'array',
                    items: {
                      type: 'object' as const,
                      properties: {
                        id: { type: 'integer' },
                        public: { type: 'string' },
                        signature: { type: 'string' },
                      },
                    },
                  },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Prekeys added',
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    message: { type: 'string' },
                    one_time_prekeys_added: { type: 'integer' },
                    kyber_prekeys_added: { type: 'integer' },
                  },
                },
              },
            },
          },
          '404': { description: 'No active key set for this user' },
        },
      },
    },
    '/devices/keys/rotate-signed': {
      post: {
        tags: ['E2EE'],
        summary: 'Swap in a fresh signed prekey (weekly rotation)',
        security: [{ BearerAuth: [] }],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object' as const,
                required: ['signed_prekey'],
                properties: {
                  signed_prekey: {
                    type: 'object' as const,
                    required: ['id', 'public', 'signature'],
                    properties: {
                      id: { type: 'integer' },
                      public: { type: 'string' },
                      signature: { type: 'string' },
                    },
                  },
                },
              },
            },
          },
        },
        responses: {
          '200': { description: 'Signed prekey rotated' },
          '404': { description: 'No active key set for this user' },
        },
      },
    },
    '/devices/revoke': {
      post: {
        tags: ['E2EE'],
        summary: 'Revoke the active key set (sign-out)',
        description:
          'Marks device_keys.revoked_at = now and DELETEs all OTPKs + ' +
          'Kyber prekeys so the (user_id, key_id) namespace is free ' +
          'for the next upload. Idempotent when no active set exists.',
        security: [{ BearerAuth: [] }],
        responses: {
          '200': { description: 'Revoked (or no-op)' },
        },
      },
    },
    '/users/{id}/keybundle': {
      get: {
        tags: ['E2EE'],
        summary: "Fetch a peer's key bundle for X3DH + PQ-hybrid setup",
        description:
          'Atomically consumes one OTPK + one Kyber prekey. Rate limited ' +
          'at 60/hour per requester to cap OTPK-exhaustion abuse. Returns ' +
          '503 if the target has no unconsumed Kyber prekeys (libsignal ' +
          "can't build a PreKeyBundle without one); the OTPK consumption " +
          'is rolled back in that case.',
        security: [{ BearerAuth: [] }],
        parameters: [
          { name: 'id', in: 'path' as const, required: true, schema: { type: 'string', format: 'uuid' } },
        ],
        responses: {
          '200': {
            description: "Peer's key bundle",
            content: {
              'application/json': {
                schema: {
                  type: 'object' as const,
                  properties: {
                    identity_key_pub: { type: 'string' },
                    signed_prekey: {
                      type: 'object' as const,
                      properties: {
                        id: { type: 'integer' },
                        public: { type: 'string' },
                        signature: { type: 'string' },
                      },
                    },
                    one_time_prekey: {
                      nullable: true,
                      type: 'object' as const,
                      properties: {
                        id: { type: 'integer' },
                        public: { type: 'string' },
                      },
                    },
                    kyber_prekey: {
                      type: 'object' as const,
                      properties: {
                        id: { type: 'integer' },
                        public: { type: 'string' },
                        signature: { type: 'string' },
                      },
                    },
                  },
                },
              },
            },
          },
          '404': { description: 'No active key set for target user' },
          '503': { description: 'Kyber prekey pool exhausted' },
        },
      },
    },
  },
  tags: [
    { name: 'Auth', description: 'Authentication and session management' },
    { name: 'Users', description: 'User profiles' },
    { name: 'Follows', description: 'Follow and mutual-follow relationships' },
    { name: 'Invites', description: 'Invite code management' },
    { name: 'Feed', description: 'Chronological post feed' },
    { name: 'Posts', description: 'Post CRUD and media uploads' },
    { name: 'Comments', description: 'Comments on posts' },
    { name: 'Stories', description: 'Ephemeral stories (24h)' },
    { name: 'Conversations', description: 'Direct messaging' },
    { name: 'Lists', description: 'Curated friend lists for scoping post visibility and filtering the feed' },
    { name: 'E2EE', description: 'End-to-end-encrypted DM key registry + session setup' },
  ],
};

export function serveOpenApiDocs(app: Express): void {
  app.get('/openapi.json', (_req, res) => {
    res.json(openApiSpec);
  });

  app.use('/docs', swaggerUi.serve, swaggerUi.setup(openApiSpec));
}
