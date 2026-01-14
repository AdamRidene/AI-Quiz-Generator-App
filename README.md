# Quizzy - AI Quiz Generator

![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white)
![Dart](https://img.shields.io/badge/dart-%230175C2.svg?style=for-the-badge&logo=dart&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-3ECF8E?style=for-the-badge&logo=supabase&logoColor=white)
![Gemini API](https://img.shields.io/badge/Google%20Gemini-8E75B2?style=for-the-badge&logo=google%20gemini&logoColor=white)
![Rive](https://img.shields.io/badge/Rive-D93563?style=for-the-badge&logo=rive&logoColor=white)

**Quizzy** is a dynamic Flutter application that uses the **Gemini API** to generate unique quizzes on the fly and **Supabase** for backend management. It features an engaging user interface enhanced with high-quality **Rive** animations.

## ✨ Features

* **AI-Powered Questions**: Generates endless quiz questions on any topic using Google's Gemini API.
* **Supabase Backend**: Secure authentication and data management.
* **Interactive Animations**:
    * `geometric_shape_loader.riv`: Modern visual feedback.
    * `tick.riv`: Contains loading state while fetching questions and success states (two animations, one for fetching questions and another one after quiz completion).
* **Cross-Platform**: Built with Flutter for seamless performance on Android, iOS, Web, and Desktop.

## 🛠️ Tech Stack

* **Framework**: [Flutter](https://flutter.dev/)
* **Language**: [Dart](https://dart.dev/)
* **Backend**: [Supabase](https://supabase.com/)
* **AI Service**: [Google Gemini API](https://ai.google.dev/)
* **Animations**: [Rive](https://rive.app/)

## 🚀 Getting Started

### Prerequisites

* Flutter SDK installed
* A Google Cloud Project with the **Gemini API** enabled
* A **Supabase** project (for URL & Anon Key)
* An API Key from [Google AI Studio](https://aistudio.google.com/)

### Installation

1.  **Clone the repository**
    ```bash
    git clone [https://github.com/adamridene/ai-quiz-generator-app.git](https://github.com/adamridene/ai-quiz-generator-app.git)
    cd ai-quiz-generator-app
    ```

2.  **Install dependencies**
    ```bash
    flutter pub get
    ```

3.  **Setup Environment**
    * Configure your **Gemini API key** and **Supabase credentials** in your project (ensure you do not commit these keys to version control).

4.  **Run the App**
    ```bash
    flutter run
    ```

## 📂 Project Structure

```text
lib/
└── main.dart                  # Application entry point
assets/
├── geometric_shape_loader.riv # General loading animation
└── tick.riv                   # Success/Completion animation, loading questions (Contains multiple state machines)
