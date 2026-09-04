/**
 * Translate a Supabase write failure into a domain error the UI can present.
 *
 * THE DATABASE'S CONTRACT (migration 0008, and 0003 for the unique index):
 *
 *   Every timezone domain violation raises SQLSTATE 23514 (check_violation)
 *   with a stable machine-readable token in DETAIL, which PostgREST surfaces
 *   as `details`. The MESSAGE is written for humans and logs; its wording is
 *   free to change, so it is never parsed here. The constraint name is not used
 *   as the identifier either — PostgREST does not pass it through.
 *
 *   That is why the token, not the SQLSTATE, is the discriminator: 23514 is
 *   shared with the placement CHECK and with any future constraint.
 *
 * Anything unrecognised becomes a plain Error carrying the server's message, so
 * no failure is ever swallowed.
 */

import {
  DuplicateExceptionError,
  InvalidTimezoneError,
  TimezoneClearedError,
  TimezoneRequiredError,
} from '../errors';

/** The parts of a PostgrestError this mapping reads. */
export interface WriteErrorLike {
  code?: string | null;
  details?: string | null;
  message?: string | null;
}

export function mapEventWriteError(error: WriteErrorLike): Error {
  // Partial unique index on (recurrence_id, slot key): the occurrence already
  // has an override or cancellation.
  if (error.code === '23505') return new DuplicateExceptionError();

  switch (error.details) {
    case 'TIMEWEAVE_TZ_INVALID':
      return new InvalidTimezoneError();
    case 'TIMEWEAVE_TZ_REQUIRED':
      return new TimezoneRequiredError();
    case 'TIMEWEAVE_TZ_CLEARED':
      return new TimezoneClearedError();
    default:
      return new Error(error.message ?? 'Unknown database error');
  }
}
