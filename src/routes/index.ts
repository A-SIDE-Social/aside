import { Router } from 'express';
import { authenticate } from '../middleware/auth';
import authRouter from './auth';
import usersRouter from './users';
import followsRouter from './follows';
import invitesRouter from './invites';
import inviteLinkRouter from './invite-link';
import feedRouter from './feed';
import postsRouter from './posts';
import uploadsRouter from './uploads';
import commentsRouter from './comments';
import storiesRouter from './stories';
import conversationsRouter from './conversations';
import groupsRouter from './groups';
import devicesRouter from './devices';
import dmAttachmentsRouter from './dm_attachments';
import contactsRouter from './contacts';
import webhooksRouter from './webhooks';
import subscriptionsRouter from './subscriptions';
import reactionsRouter from './reactions';

export const router = Router();

// Public routes (no auth)
router.use('/auth', authRouter);
router.use('/invites', invitesRouter); // has its own auth per-route (validate is public)
router.use('/webhooks', webhooksRouter); // RevenueCat server-to-server, auth via shared secret
router.use('/', uploadsRouter); // dev upload/serve — no auth, like S3 presigned URLs

// Authenticated routes
router.use('/users', authenticate, usersRouter);
router.use('/follows', authenticate, followsRouter);
// Personal invite link surface — slug GET/regenerate/request lives
// here. Each route auth-gates internally so the redirect-to-signup
// flow can call POST /request as soon as the user is authenticated.
router.use('/invite-link', inviteLinkRouter);
router.use('/feed', authenticate, feedRouter);
router.use('/posts', authenticate, postsRouter);
router.use('/stories', authenticate, storiesRouter);
router.use('/conversations', authenticate, conversationsRouter);
// "Lists" is the user-facing name. /v1/groups is kept as an alias for
// legacy mobile clients (builds ≤ 28 call /v1/groups) and will be
// removed once TestFlight adoption migrates. Both paths hit the same
// handlers; data model stays internally named `groups`.
router.use('/lists', authenticate, groupsRouter);
router.use('/groups', authenticate, groupsRouter);
router.use('/devices', authenticate, devicesRouter);
router.use('/dm-attachments', authenticate, dmAttachmentsRouter);
router.use('/contacts', authenticate, contactsRouter);
router.use('/subscriptions', authenticate, subscriptionsRouter);
router.use('/', commentsRouter); // comments handles its own auth; routes: /posts/:id/comments, /comments/:id
// Reactions: /posts/:id/reactions/toggle + /posts/:id/reactions/:emoji/users.
// Mounted at root with `authenticate` because the route paths are
// prefixed with /posts/:postId/... and we want them under /v1.
router.use('/', authenticate, reactionsRouter);
