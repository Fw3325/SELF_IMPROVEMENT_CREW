# Self Improvement Crew
Goal: Empower students and professionals pursuing personal growth and career advancement through personalized mentorship and learning plans. 

With three individual assistants (Learning, Freelancer, and Newsletter Assistants), this Self-Improvement Crew leverages advanced AI technology and adapts to each user's unique learning style and pace, optimizing educational outcomes and fostering continuous development.

The prototype/MVP of the product includes the following key features:
- Personalized Recommendations: Analyzes users' goals, skill levels, interests, and learning styles to recommend courses.
- Study Plan: Creates and adjusts study plans based on user progress, feedback/notes, and performance analytics.
- Newsletter Delivery: Sends personalized weekly newsletters summarizing the latest industry trends and top voices.
- Resume and Cover Letter Builder: Provides AI assistance for updating resumes, cover letters, and interview preparation questions based on job descriptions. 

# Docker build and run for course_rec_demo.py

docker build -t course_rec_app .
docker run -d -p 8000:8000 course_rec_app

# Access the app at http://localhost:8000 or http://<your-local-ip>:8000

# Deploy to AWS ECS
1. pip install awscli # install aws cli
2. aws configure # setup aws key etc...
3. bash test_service.sh # run test_service to test if test case can be deployed
4. bash run.sh # deploy the full service