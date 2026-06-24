import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  type ReactNode,
} from "react";
import AsyncStorage from "@react-native-async-storage/async-storage";

const SETTINGS_KEY = "@hydrolyze/settings";

export interface AppSettings {
  showPairingConfidence: boolean;
}

const DEFAULT_SETTINGS: AppSettings = {
  showPairingConfidence: false,
};

interface SettingsContextValue {
  settings: AppSettings;
  updateSettings: (partial: Partial<AppSettings>) => Promise<void>;
  isLoaded: boolean;
}

const SettingsContext = createContext<SettingsContextValue | null>(null);

export function SettingsProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [isLoaded, setIsLoaded] = useState(false);

  useEffect(() => {
    AsyncStorage.getItem(SETTINGS_KEY)
      .then((stored) => {
        if (stored) {
          try {
            setSettings({ ...DEFAULT_SETTINGS, ...JSON.parse(stored) });
          } catch {
            setSettings(DEFAULT_SETTINGS);
          }
        }
      })
      .finally(() => setIsLoaded(true));
  }, []);

  async function updateSettings(partial: Partial<AppSettings>) {
    const next = { ...settings, ...partial };
    setSettings(next);
    await AsyncStorage.setItem(SETTINGS_KEY, JSON.stringify(next));
  }

  return (
    <SettingsContext.Provider value={{ settings, updateSettings, isLoaded }}>
      {children}
    </SettingsContext.Provider>
  );
}

export function useSettings(): AppSettings {
  const ctx = useContext(SettingsContext);
  if (!ctx) throw new Error("useSettings must be used within SettingsProvider");
  return ctx.settings;
}

export function useSettingsContext(): SettingsContextValue {
  const ctx = useContext(SettingsContext);
  if (!ctx)
    throw new Error("useSettingsContext must be used within SettingsProvider");
  return ctx;
}
