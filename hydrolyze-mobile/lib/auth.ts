/**
 * Auth helper — wraps Supabase Auth with app-specific helpers.
 */

import { supabase } from "./supabase";
import type { Session, User } from "@supabase/supabase-js";

export type AuthState = {
  session: Session | null;
  user: User | null;
  loading: boolean;
};

/** Get the current coach_id from the coaches table using auth.uid() */
export async function getCoachId(authId: string): Promise<string | null> {
  const { data } = await supabase
    .from("coaches")
    .select("id")
    .eq("auth_id", authId)
    .single();
  return data?.id ?? null;
}

/** Create or fetch the coach record for the current auth user */
export async function getOrCreateCoach(
  user: User,
): Promise<{
  id: string;
  name: string | null;
  pool_units: string | null;
  onboarding_completed_at: string | null;
} | null> {
  const { data } = await supabase
    .from("coaches")
    .select("id, name, pool_units, onboarding_completed_at")
    .eq("auth_id", user.id)
    .single();

  if (data)
    return {
      id: data.id,
      name: data.name,
      pool_units: data.pool_units,
      onboarding_completed_at: data.onboarding_completed_at,
    };

  const { data: inserted, error } = await supabase
    .from("coaches")
    .insert({ auth_id: user.id, name: user.user_metadata?.name ?? null })
    .select("id, name, pool_units, onboarding_completed_at")
    .single();

  if (error) {
    console.error("[auth] getOrCreateCoach error:", error);
    return null;
  }
  return {
    id: inserted.id,
    name: inserted.name,
    pool_units: inserted.pool_units,
    onboarding_completed_at: inserted.onboarding_completed_at,
  };
}

/** Check whether the current user has completed onboarding */
export async function hasCompletedOnboarding(
  coachId: string,
): Promise<boolean> {
  const { data } = await supabase
    .from("coaches")
    .select("onboarding_completed_at")
    .eq("id", coachId)
    .single();
  return !!data?.onboarding_completed_at;
}

/** Update the coach's name */
export async function updateCoachName(
  coachId: string,
  name: string,
): Promise<void> {
  await supabase.from("coaches").update({ name }).eq("id", coachId);
}

/** Update coach profile fields */
export async function updateCoachProfile(
  coachId: string,
  fields: { name?: string; pool_units?: string },
): Promise<void> {
  const { error } = await supabase
    .from("coaches")
    .update(fields)
    .eq("id", coachId);
  if (error) console.error("[auth] updateCoachProfile error:", error);
}

/** Create a team for a coach */
export async function createTeam(coachId: string, name: string): Promise<void> {
  const { error } = await supabase
    .from("teams")
    .insert({ coach_id: coachId, name });
  if (error) console.error("[auth] createTeam error:", error);
}

/** Mark onboarding as complete */
export async function completeOnboarding(coachId: string): Promise<void> {
  const { error } = await supabase
    .from("coaches")
    .update({ onboarding_completed_at: new Date().toISOString() })
    .eq("id", coachId);
  if (error) console.error("[auth] completeOnboarding error:", error);
}
