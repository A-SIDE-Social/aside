describe('config hardening', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    jest.resetModules();
    process.env = { ...originalEnv };
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  function loadConfig() {
    let loaded: any;
    jest.isolateModules(() => {
      loaded = require('../src/config').config;
    });
    return loaded;
  }

  test('requires NODE_ENV to be explicitly set', () => {
    delete process.env.NODE_ENV;
    expect(() => loadConfig()).toThrow(/NODE_ENV must be explicitly set/);
  });

  test('rejects invalid NODE_ENV values', () => {
    process.env.NODE_ENV = 'staging';
    expect(() => loadConfig()).toThrow(/NODE_ENV must be one of/);
  });

  test('production rejects missing secrets', () => {
    process.env.NODE_ENV = 'production';
    delete process.env.JWT_SECRET;
    process.env.JWT_REFRESH_SECRET = 'strong-refresh-secret';
    process.env.COOKIE_SECRET = 'strong-cookie-secret';

    expect(() => loadConfig()).toThrow(/JWT_SECRET must be a strong secret/);
  });

  test('production rejects known default secrets', () => {
    process.env.NODE_ENV = 'production';
    process.env.JWT_SECRET = 'dev-secret';
    process.env.JWT_REFRESH_SECRET = 'strong-refresh-secret';
    process.env.COOKIE_SECRET = 'strong-cookie-secret';
    expect(() => loadConfig()).toThrow(/JWT_SECRET must be a strong secret/);

    process.env.JWT_SECRET = 'strong-jwt-secret';
    process.env.JWT_REFRESH_SECRET = 'dev-refresh-secret';
    expect(() => loadConfig()).toThrow(
      /JWT_REFRESH_SECRET must be a strong secret/,
    );

    process.env.JWT_REFRESH_SECRET = 'strong-refresh-secret';
    process.env.COOKIE_SECRET = 'change-me-cookie';
    expect(() => loadConfig()).toThrow(/COOKIE_SECRET must be a strong secret/);
  });

  test('development and test boot with explicit NODE_ENV', () => {
    process.env.NODE_ENV = 'development';
    delete process.env.JWT_SECRET;
    delete process.env.JWT_REFRESH_SECRET;
    delete process.env.COOKIE_SECRET;
    expect(loadConfig().nodeEnv).toBe('development');

    jest.resetModules();
    process.env.NODE_ENV = 'test';
    expect(loadConfig().nodeEnv).toBe('test');
  });

  test('uses 15 minute access tokens and separate cookie secret', () => {
    process.env.NODE_ENV = 'test';
    process.env.COOKIE_SECRET = 'test-cookie-secret';
    const config = loadConfig();
    expect(config.jwtExpiresIn).toBe('15m');
    expect(config.cookieSecret).toBe('test-cookie-secret');
  });
});
