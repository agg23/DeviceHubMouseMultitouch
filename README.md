# Mouse Multitouch Support for Xcode Device Hub

> [!WARNING]
> Unlike almost all of my other content, this repository is almost entirely produced via LLMs.

Xcode 27 introduced the new Device Hub, which drops the Simulator feature to hold Option to perform multitouch gestures, such as pinch, while using a mouse. Device Hub _does_ support multitouch gestures when using a multitouch trackpad, but not with a mouse.

This tool restores the mouse functionality, and renders "virtual fingers" like the lost Simulator functionality.

## Usage

1. Run the app, and it will ask for Accessibility permissions.
2. Grand the permissions
3. Run the app again
4. You should now be able to hold Option in Device Hub and perform multitouch gestures

I recommend you add it to Login Items via System Settings > General > Login Items, so it runs automatically on login.
