import Foundation

struct PurposeSuggestions {
  static let arrays: [String: [String]] = [
    "love": [
      "Music", "Recipes", "Architecture", "Writing", "Nature", "Mentoring", "Puzzles",
      "Martial Arts", "Improv", "Sculpture", "Wildlife", "Technology", "Poetry", "Sports",
      "Photography", "Gardening", "Foodie", "Dance", "Animals", "Cinema", "Board Games",
      "Storytelling", "Astronomy", "Cosplay", "Instruments", "History", "Podcasting",
      "Origami", "Reading", "Painting", "Hiking", "Cooking", "Dancing", "Singing",
      "Volunteering", "Traveling", "Yoga", "Playing Music", "Stargazing", "Surfing",
      "Coding", "Meditating", "Rock Climbing", "Birdwatching", "Woodworking", "Journaling",
      "Knitting", "Skydiving", "Scuba Diving", "Chess", "Public Speaking", "Film-Making",
      "Animal Rescue",
    ],
    "identity": [
      "Problem-Solver", "Listener", "Leader", "Innovator", "Communicator", "Organizer",
      "Analyst", "Storyteller", "Mediator", "Designer", "Motivator", "Strategist",
      "Researcher", "Negotiator", "Artist", "Athlete", "Mentor", "Collaborator",
      "Visionary", "Diplomat", "Programmer", "Educator", "Entrepreneur", "Healer",
      "Performer", "Coordinator", "Inventor", "Networker", "Peacemaker", "Scientist",
      "Explorer", "Curator", "Advocate", "Consultant", "Engineer", "Writer", "Developer",
    ],
    "value": [
      "Skill Development", "Course Creation", "Real Estate", "Consultancy",
      "Professional Services", "Trading", "Freelancing", "Venture Building", "Coaching",
      "Investing", "Bespoke Services", "Branding", "Marketing", "Consulting", "AI",
      "Product Design", "Software Development", "Team Management", "Business Development",
      "Project Management", "Sales", "Customer Service", "Product Management",
      "Data Analysis", "Content Creation", "Digital Marketing", "Financial Planning",
      "Event Planning", "Research", "Teaching", "Writing", "Design", "Programming",
      "Mentoring", "Public Speaking", "Leadership Training",
    ],
    "world": [
      "Free Education Content", "Pro Bono Services", "Youth Mentoring", "Awareness Art",
      "Support Networks", "Cultural Dialogue", "Elderly Care", "Ocean Cleanup",
      "Sustainable Agriculture", "Conflict Resolution", "Environmental Stewardship",
      "Social Justice", "Education", "Peacekeeping", "Poverty Alleviation", "Mental Health",
      "Child Welfare", "Sustainability", "Disaster Relief", "Community Building",
      "Renewable Energy", "Food Security", "Clean Water", "Literacy", "Animal Welfare",
      "Arts Preservation", "Cultural Exchange", "Technological Advancement", "Human Rights",
      "Scientific Research", "Economic Development", "Digital Inclusion", "Healthcare Access",
      "Environmental Conservation", "Disability Advocacy", "Refugee Support",
    ],
  ]

  static func getRandomSuggestions(for category: String) -> [String] {
    guard let suggestions = arrays[category], !suggestions.isEmpty else { return [] }
    let shuffled = Array(Set(suggestions)).shuffled()
    var result: [String] = []
    var index = 0

    while result.count < 5 {
      result.append(shuffled[index % shuffled.count])
      index += 1
    }

    return result
  }
}
