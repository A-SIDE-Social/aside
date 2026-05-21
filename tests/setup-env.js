process.env.NODE_ENV = process.env.NODE_ENV || 'test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'dev-secret';
process.env.JWT_REFRESH_SECRET =
  process.env.JWT_REFRESH_SECRET || 'dev-refresh-secret';
process.env.COOKIE_SECRET = process.env.COOKIE_SECRET || 'dev-cookie-secret';
process.env.DEV_OTP = process.env.DEV_OTP || '123456';
