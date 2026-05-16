import { Router } from 'express';
import fs from 'fs';
import path from 'path';
import { config } from '../config';
import { asyncHandler } from '../helpers';
import { AppError } from '../middleware/errorHandler';

const router = Router();

const uploadsDir = path.join(__dirname, '../../uploads');

// PUT /posts/upload/:filename - Dev-only local file upload (no auth, like S3 presigned URLs)
router.put(
  '/posts/upload/:filename',
  asyncHandler(async (req: any, res: any) => {
    if (config.nodeEnv !== 'development' && config.nodeEnv !== 'test') {
      throw new AppError(404, 'Not found');
    }

    if (!fs.existsSync(uploadsDir)) {
      fs.mkdirSync(uploadsDir, { recursive: true });
    }

    const filename = path.basename(req.params.filename); // prevent path traversal
    const filePath = path.join(uploadsDir, filename);

    // Save content type metadata
    const contentType = req.headers['content-type'] || 'application/octet-stream';
    fs.writeFileSync(`${filePath}.meta`, contentType);

    if (Buffer.isBuffer(req.body)) {
      fs.writeFileSync(filePath, req.body);
      res.json({ message: 'Uploaded' });
    } else {
      const chunks: Buffer[] = [];
      req.on('data', (chunk: Buffer) => chunks.push(chunk));
      req.on('end', () => {
        fs.writeFileSync(filePath, Buffer.concat(chunks));
        res.json({ message: 'Uploaded' });
      });
    }
  }),
);

// GET /posts/upload/:filename - Dev-only serve uploaded files (no auth, like CloudFront)
router.get(
  '/posts/upload/:filename',
  (req: any, res: any) => {
    const filename = path.basename(req.params.filename);
    const filePath = path.join(uploadsDir, filename);
    if (!fs.existsSync(filePath)) {
      return res.status(404).json({ error: 'File not found' });
    }

    // Read saved content type, or guess from file signature
    const metaPath = `${filePath}.meta`;
    let contentType = 'application/octet-stream';
    if (fs.existsSync(metaPath)) {
      contentType = fs.readFileSync(metaPath, 'utf-8').trim();
    } else {
      // Sniff from first bytes
      const fd = fs.openSync(filePath, 'r');
      const buf = Buffer.alloc(12);
      fs.readSync(fd, buf, 0, 12, 0);
      fs.closeSync(fd);
      if (buf[0] === 0xFF && buf[1] === 0xD8) {
        contentType = 'image/jpeg';
      } else if (buf[0] === 0x89 && buf.toString('ascii', 1, 4) === 'PNG') {
        contentType = 'image/png';
      } else if (buf.toString('ascii', 4, 8) === 'ftyp') {
        contentType = 'video/mp4';
      }
    }

    res.setHeader('Content-Type', contentType);
    res.sendFile(filePath);
  },
);

export default router;
