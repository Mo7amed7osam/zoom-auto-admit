using ZoomAutoAdmit.WebAutomation.Models;

namespace ZoomAutoAdmit.WebAutomation;

public static class WebAdmissionPolicy
{
    public static WebAdmissionDecision Decide(WebWaitingRoomSnapshot snapshot)
    {
        if (!snapshot.MeetingActive || !snapshot.WaitingRoomExists || snapshot.WaitingCount <= 0)
            return new(WebAdmissionKind.None, null, "No active Waiting Room participants were found.");

        if (snapshot.WaitingCount >= 2)
        {
            return snapshot.AdmitAllAvailable
                ? new(WebAdmissionKind.AdmitAll, null, "Two or more participants are waiting and exact Admit all is available.")
                : new(WebAdmissionKind.None, null, "Two or more participants are waiting; waiting for exact Admit all.");
        }

        var participant = snapshot.WaitingCount == 1 ? snapshot.Participants.FirstOrDefault() : null;
        return participant == null
            ? new(WebAdmissionKind.None, null, "Waiting Room exists, but no exact individual Admit row is currently actionable.")
            : new(WebAdmissionKind.Single, participant, "An exact Admit button is available inside the participant row.");
    }
}
