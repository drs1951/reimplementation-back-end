class User < ApplicationRecord
  has_secure_password
  after_initialize :set_defaults

  # name must be lowercase and unique
  validates :name, presence: true, uniqueness: true, allow_blank: false,
                   format: { with: /\A[a-z]+\z/, message: 'must be in lowercase' }
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 6 }, presence: true, allow_nil: true
  validates :full_name, presence: true, length: { maximum: 50 }

  belongs_to :role
  belongs_to :institution, optional: true
  belongs_to :parent, class_name: 'User', optional: true
  has_many :users, foreign_key: 'parent_id', dependent: :nullify
  has_many :invitations
  has_many :assignments, through: :participants

  scope :students, -> { where role_id: Role::STUDENT }
  scope :tas, -> { where role_id: Role::TEACHING_ASSISTANT }
  scope :instructors, -> { where role_id: Role::INSTRUCTOR }
  scope :administrators, -> { where role_id: Role::ADMINISTRATOR }
  scope :superadministrators, -> { where role_id: Role::SUPER_ADMINISTRATOR }

  delegate :student?, to: :role
  delegate :ta?, to: :role
  delegate :instructor?, to: :role
  delegate :administrator?, to: :role
  delegate :super_administrator?, to: :role

  def self.instantiate(record)
    case record.role
    when Role::TEACHING_ASSISTANT
      record.becomes(Ta)
    when Role::INSTRUCTOR
      record.becomes(Instructor)
    when Role::ADMINISTRATOR
      record.becomes(Administrator)
    when Role::SUPER_ADMINISTRATOR
      record.becomes(SuperAdministrator)
    else
      super
    end
  end

  # Welcome email to be sent to the user after they sign up
  def welcome_email; end

  # Return a user object if the user is found in the database, the input can be either email or name
  def self.login_user(login)
    user = User.find_by(email: login)
    if user.nil?
      short_name = login.split('@').first
      user_list = User.where(name: short_name)
      user = user_list.first if user_list.one?
    end
    user
  end

  # Reset the password for the user
  def reset_password
    random_password = SecureRandom.alphanumeric(10)
    user.password_digest = BCrypt::Password.create(random_password)
    user.save
  end

  # Get instructor_id of the user, if the user is TA,
  # return the id of the instructor else return the id of the user for superior roles
  def instructor_id
    case role
    when Role::INSTRUCTOR, Role::ADMINISTRATOR, Role::SUPER_ADMINISTRATOR
      id
    when Role::TEACHING_ASSISTANT
      my_instructor
    else
      raise NotImplementedError, "Unknown role: #{role.name}"
    end
  end

  def self.from_params(params)
    user = params[:user_id] ? User.find(params[:user_id]) : User.find_by(name: params[:user][:name])
    raise "User #{params[:user_id] || params[:user][:name]} not found" if user.nil?

    user
  end

  # Fetches available users whose full names match the provided name prefix (case-insensitive).
  # Returns a limited list of users (up to 10) who have roles similar or subordinate to the current user's role.
  def get_available_users(name)
    lesser_roles = role.subordinate_roles_and_self
    all_users = User.where('full_name LIKE ?', "%#{name}%").limit(20)
    visible_users = all_users.select { |user| lesser_roles.include? user.role }
    visible_users[0, 10] # the first 10
  end

  # Check if the user can impersonate another user
  def can_impersonate?(user)
    return true if role.super_administrator?
    return true if instructor_for?(user)
    # Skip below check if user's role is "Instructor"
    return false if instructor?
    return true if teaching_assistant_for?(user)
    # Skip recursively_parent_of check if user's role is "Teaching Assistant"
    return false if teaching_assistant?
    return true if recursively_parent_of(user.role)
    false
  end

  # Check if the current user is an instructor and has any relationship with the given user (student or TA)
  def instructor_for?(user)
    return false unless instructor?
    return true if instructor_for_student?(user)
    return true if instructor_for_ta?(user)
  end

  # Helper method to check if there are any courses where a student is enrolled in assignments
  def courses_where_student_participates(courses, student)
    courses.any? do |course|
      course.assignments.any? do |assignment|
        assignment.participants.map(&:user_id).include?(student.id)
      end
    end
  end

  # Check if the instructor has any relationship with the given student
  def instructor_for_student?(student)
    return false unless student.role.name == 'Student'  # Ensure the role is 'Student'

    instructor = Instructor.find(id)

    # Check if the instructor has any courses where the student is enrolled in an assignment
    return courses_where_student_participates(Instructor.list_all(Course, instructor),student)
  end

  # Check if the instructor has common courses with the given teaching assistant
  def instructor_for_ta?(ta)
    return false unless ta.role.name == 'Teaching Assistant'  # Ensure the role is 'Teaching Assistant'

    instructor = Instructor.find(id)

    # Get all courses taught by the instructor
    instructor_courses = Instructor.list_all(Course, instructor)

    # Get all courses associated with the TA
    ta_courses = TaMapping.get_courses(ta)

    # Convert lists to sets for efficient intersection
    instructor_course_set = instructor_courses.to_set
    ta_course_set = ta_courses.to_set

    # Check for common courses using set intersection
    has_common_course = !(instructor_course_set & ta_course_set).empty?

    return has_common_course
  end

  # Check if the user is a teaching assistant for the student's course
  def teaching_assistant_for?(student)
    return false unless teaching_assistant?
    return false unless student.role.name == 'Student'

    # We have to use the Ta object instead of User object
    # because single table inheritance is not currently functioning
    ta = Ta.find(id)

    # Check if the TA has any courses where the student is enrolled in an assignment
    return courses_where_student_participates(TaMapping.get_courses(ta),student)

    false
  end

  # Check if the user is a teaching assistant
  def teaching_assistant?
    true if role.ta?
  end

  # Recursively check if parent child relationship exists
  def recursively_parent_of(user_role)
    p = user_role.parent
    return false if p.nil?
    return true if p == self.role
    return false if p.super_administrator?
    recursively_parent_of(p)
  end


  # This will override the default as_json method in the ApplicationRecord class and specify
  # that only the id, name, and email attributes should be included when a User object is serialized.
  def as_json(options = {})
    super(options.merge({
                          only: %i[id name email full_name email_on_review email_on_submission
                                   email_on_review_of_review],
                          include:
                          {
                            role: { only: %i[id name] },
                            parent: { only: %i[id name] },
                            institution: { only: %i[id name] }
                          }
                        })).tap do |hash|
      hash['parent'] ||= { id: nil, name: nil }
      hash['institution'] ||= { id: nil, name: nil }
    end
  end

  def set_defaults
    self.is_new_user = true
    self.copy_of_emails ||= false
    self.email_on_review ||= false
    self.email_on_submission ||= false
    self.email_on_review_of_review ||= false
    self.etc_icons_on_homepage ||= true
  end
end
