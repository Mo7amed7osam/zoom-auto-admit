using ZoomAutoAdmit.WebAutomation.Models;

namespace ZoomAutoAdmit.WebAutomation;

public static class WebAdmissionVerifier
{
    public static WebAdmissionVerification Evaluate(
        WebWaitingRoomSnapshot before,
        WebWaitingRoomSnapshot after,
        WebAdmissionDecision action)
    {
        if (!after.MeetingActive)
            return new(false, false, "The meeting page disappeared before admission could be verified.");

        bool countDecreased = after.WaitingCount < before.WaitingCount;
        if (action.Kind == WebAdmissionKind.AdmitAll)
        {
            bool originalParticipantsGone = before.Participants.Count > 0 && before.Participants.All(beforeParticipant =>
                after.Participants.All(afterParticipant =>
                    !afterParticipant.Identity.Equals(beforeParticipant.Identity, StringComparison.OrdinalIgnoreCase)));
            bool verified = countDecreased || originalParticipantsGone;
            return verified
                ? new(true, false, countDecreased
                    ? "The Waiting Room count decreased."
                    : "The original Waiting Room batch disappeared.")
                : new(false, after.WaitingRoomExists && after.WaitingCount > 0,
                    "The Waiting Room batch is still present after Admit all.");
        }

        if (action.Kind == WebAdmissionKind.Single && action.Participant != null)
        {
            bool participantGone = after.Participants.All(participant =>
                !participant.Identity.Equals(action.Participant.Identity, StringComparison.OrdinalIgnoreCase));
            int joinedBefore = before.JoinedParticipantIdentities.Count(identity =>
                identity.Equals(action.Participant.Identity, StringComparison.OrdinalIgnoreCase));
            int joinedAfter = after.JoinedParticipantIdentities.Count(identity =>
                identity.Equals(action.Participant.Identity, StringComparison.OrdinalIgnoreCase));
            bool participantNewlyJoined = joinedAfter > joinedBefore;
            bool notificationWasPresent = before.ArrivalNotificationParticipantIdentities.Any(identity =>
                identity.Equals(action.Participant.Identity, StringComparison.OrdinalIgnoreCase));
            bool notificationDisappeared = notificationWasPresent &&
                after.ArrivalNotificationParticipantIdentities.All(identity =>
                    !identity.Equals(action.Participant.Identity, StringComparison.OrdinalIgnoreCase));
            bool verified = notificationDisappeared || participantGone || countDecreased || participantNewlyJoined;
            return verified
                ? new(true, false,
                    notificationDisappeared
                        ? "The Waiting Room notification disappeared."
                        : participantNewlyJoined
                        ? "Another participant instance appeared in the Joined list."
                        : countDecreased
                            ? "The Waiting Room count decreased."
                            : "The participant disappeared from the Waiting Room list.")
                : new(false, true, "The participant is still present while the Zoom UI updates.");
        }

        return new(false, false, "No admission action was available to verify.");
    }
}
