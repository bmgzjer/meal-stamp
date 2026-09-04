import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.mealstamp.couple',
  appName: '准时吃饭打卡',
  webDir: 'dist',
  android: {
    allowMixedContent: false,
    backgroundColor: '#FFF9E9'
  }
};

export default config;
