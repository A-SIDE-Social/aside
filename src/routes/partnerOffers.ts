import { Router } from 'express';
import { config } from '../config';
import { writeLimit } from '../middleware/rateLimit';
import { resolvePartnerOffer } from '../services/partnerOffers';

const router = Router();
router.post('/resolve', writeLimit, (req, res) => {
  res.set('Cache-Control', 'no-store');
  const { code, platform, country } = req.body ?? {};
  if (typeof code !== 'string' || !/^[A-Za-z0-9]{3,40}$/.test(code.trim()) ||
      !['ios', 'android'].includes(platform) || typeof country !== 'string' || !/^[A-Za-z]{2,3}$/.test(country)) {
    res.status(400).json({ error: 'Enter a valid partner code and store country.' });
    return;
  }
  const offer = resolvePartnerOffer(config.partnerCampaigns, {
    code: code.trim().toUpperCase(), platform, country: country.toUpperCase(),
  }, config.appleAppId);
  if (!offer) {
    res.status(404).json({ error: 'This code is unavailable or has expired for your store country.' });
    return;
  }
  res.json({ offer });
});
export default router;
