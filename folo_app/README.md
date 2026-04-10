# folo_app

A standalone RSS reader frontend for the Follow.is API built in Flutter.

## Overview

This project is a starting point for a mobile Flutter application that provides a localized RSS reading experience by interacting with the Follow.is backend API.

## Requirements & Roadmap (For Future Agents / Developers)

To ensure this project develops smoothly according to the user's expectations, please adhere to the following requirements:

1.  **Platform Focus:** Currently, the primary focus is entirely on the **Android** version. Ensure the Android app works perfectly before concerning yourself with iOS or other platforms.
2.  **Architecture:** Do **not** build or require a separate backend server. All functionality must be executed within the app itself (e.g., direct API calls, local data processing).
3.  **Frontend First:** Initially, focus completely on building and refining the frontend user interface (a standard, functional RSS reader).
4.  **AI Integration (Deferred):** Only after the frontend is fully functional and well-tested should you consider integrating AI features. When you do, these must also run locally or hit AI APIs directly from the client without a middleman server.
5.  **Reference Source:** If needed during migration or to clarify API behaviors, you are encouraged to clone and reference the original Follow (`folo`) GitHub repository. It is the root source of truth.
6.  **Debugging & Logging:** Maintain thorough debug logs (e.g., `debugPrint` for API calls, HTTP status codes, missing headers) to help the user trace issues dynamically and provide feedback to you.
7.  **Version Control:** Ensure all meaningful feature implementations or bug fixes are handled on branches properly and tested.
