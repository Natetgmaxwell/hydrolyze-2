/**
 * Global Auth Provider
 * Resolves coach identity and manages session lifecycle.
 */

import React, { createContext, useContext, useEffect, useState } from "react";
import { View, ActivityIndicator } from "react-native";
import { supabase } from "../lib/supabase";
import { getOrCreateCoach } from "../lib/auth";
import type { Session, User } from "@supabase/supabase-js";
import { Colors } from "../lib/theme";

interface AuthContextValue {
  session: Session | null;
  user: User | null;
  coachId: string | null;
  coachName: string | null;
  needsOnboarding: boolean;
  loading: boolean;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [user, setUser] = useState<User | null>(null);
  const [coachId, setCoachId] = useState<string | null>(null);
  const [coachName, setCoachName] = useState<string | null>(null);
  const [needsOnboarding, setNeedsOnboarding] = useState(false);
  const [loading, setLoading] = useState(true);
  const [authReady, setAuthReady] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session);
      setUser(session?.user ?? null);
      if (session?.user) {
        resolveCoach(session.user);
      } else {
        setAuthReady(true);
        setLoading(false);
      }
    });

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange(async (_event, session) => {
      setSession(session);
      setUser(session?.user ?? null);
      if (session?.user) {
        await resolveCoach(session.user);
      } else {
        setCoachId(null);
        setNeedsOnboarding(false);
        setLoading(false);
        setAuthReady(true);
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  async function resolveCoach(u: User) {
    const coach = await getOrCreateCoach(u);
    setCoachId(coach?.id ?? null);
    setCoachName(coach?.name ?? null);
    setNeedsOnboarding(!coach?.onboarding_completed_at);
    setLoading(false);
    setAuthReady(true);
  }

  if (!authReady) {
    return (
      <View
        style={{
          flex: 1,
          backgroundColor: Colors.base,
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <ActivityIndicator color={Colors.cyan} size="large" />
      </View>
    );
  }

  return (
    <AuthContext.Provider
      value={{ session, user, coachId, coachName, needsOnboarding, loading }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used within AuthProvider");
  return context;
}
